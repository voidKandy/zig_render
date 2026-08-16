# Alpha wrapping

[](https://inria.hal.science/hal-03688637v1/file/alpha-wrapping-author.pdf)

The core loop has about five key terms worth unpacking:
**Delaunay triangulation** - you fill all of 3D space with tetrahedra (4-sided pyramids) whose vertices are your input points, with the property that no point sits inside any tetrahedron's circumsphere (the sphere that exactly touches all 4 corners). It's a specific way of tiling space that tends to produce well-shaped, non-slivery tetrahedra.

**Carving** - you start with the convex hull of the input (imagine shrink-wrapping a box around everything) and then eat inward, removing tetrahedra from the outside one by one. The key constraint is you're only allowed to remove a tetrahedron if you can fit a ball of radius α through the face you'd enter from without hitting the input. This is what prevents carving into thin gaps or small holes.

**a-traversable** - a face between two tetrahedra is traversable if the smallest empty ball that fits through it has radius ≥ α. It's the gate condition for carving: if the gap is too tight, you can't pass through, and whatever is on the other side stays enclosed.

```zig
/// the gates are processed in order of decreasing circumradii
fn gateOrder(context: void, a: Gate, b: Gate) std.math.Order {
    /// ideally this would be implemented in a way to 
    return std.math.order(b.radius, a.radius);
}
```

**Offset surface** - instead of placing output vertices directly on the input, you place them at distance δ away from it. This is the Iδ surface in the paper. It's what guarantees the output strictly encloses the input even in degenerate cases ; your mesh vertices literally cannot be closer than δ to the input geometry.

**Refinement** - when a boundary tetrahedron (one on the edge between carved-outside and uncarved-inside) intersects the input geometry, you can't just carve it away. Instead you insert a new Steiner point on the offset surface to split it into smaller tetrahedra, pushing the boundary inward more carefully. This is how the mesh conforms to the input shape.

**Rule R1 vs R2** - the two ways to pick where to insert that Steiner point. R1 shoots a ray along the Voronoi edge (the line connecting two adjacent circumcenters) and intersects it with the offset surface - this tends to produce well-shaped triangles. R2 is the fallback: project the circumcenter directly onto the nearest point on the input, then lift it out to the offset surface. R1 is preferred because R2 can create skewed elements.

The overall loop is then: carve where you can → when you can't because a tetrahedron intersects the input, refine it → repeat until no boundary tetrahedra intersect the input and all boundary faces are non-traversable.


At a high level, the algorithm is trying to do this:

Input:
    Point cloud / mesh surface

Build:
    Delaunay tetrahedralization

Then:
    Start outside the object
          |
          v
    Walk inward through tetrahedra
          |
          v
    Stop when a tetrahedron would cross the object
          |
          v
    The boundary between outside and inside tetrahedra
    is the wrapped surface

The key idea:

A tetrahedron is either air or material.

             outside

        +--------------+
        |              |
        |    tetra     |
        |              |
        +--------------+

             inside

The algorithm is just figuring out which side each tetrahedron belongs to.

Step 1: Build Delaunay tetrahedralization
Algorithm requirement

You need:

points
  |
  v
Delaunay tetrahedralization
  |
  v

       /\ 
      /__\
     /\  /\
    /__\/__\


Every tetrahedron knows:

its vertices
its neighbors
its circumsphere
Your code

This is already done.

Your wrapper receives:

pub const Wrapper = struct {
    tri: *delaunay.Triangulation,

The wrapper assumes:

tri.tetrahedra

already exists.

Your Delaunay gives you:

tet.faces()

and:

adjacency.neighborLocation()

which is exactly what alpha wrapping needs.

The neighbor graph is the important part.

Step 2: Classify every tetrahedron as inside initially
Algorithm requirement

Before traversal:

all cells:

+---+---+---+
| I | I | I |
+---+---+---+

I = unknown/inside candidate

Then the algorithm carves away exterior cells.

Your code

Here:

pub fn init(tri, a)

you do:

tags.appendNTimes(
    a,
    .inside,
    tri.tetrahedra.items.len
);

So:

tet 0 -> inside
tet 1 -> inside
tet 2 -> inside
...

Meaning:

Assume everything is solid until proven exterior.

This is the correct starting point.

Step 3: Find the outer hull
Algorithm requirement

The outside world is not a tetrahedron.

It is:

       infinite space

          |
          v

   +-------------+
   |             |
   |  Delaunay   |
   |             |
   +-------------+


The tetrahedra touching the boundary are the entry points.

Your code

This happens here:

var iter = self.tri.tetrahedronIterator();

while (iter.next()) |entry| {

You examine every tetrahedron:

for (entry.tet.faces(), 0..) |face, face_idx|

Then:

if (self.tri.adjacency.neighborLocation(
    entry.index,
    face_idx,
    entry.tet
) != null)
    continue;

Meaning:

does this face have a neighbor?

yes:
    internal face

no:
    outer boundary

So this:

       outside
          |
          v

      +-------+
      |       |
      | tet A |
      |       |
      +-------+


gets seeded.

Step 4: Put boundary faces into a priority queue
Algorithm requirement

Not every boundary crossing is equally important.

The algorithm uses:

largest face first

because large gaps are probably empty space.

Small gaps are probably near geometry.

Your code

You create:

var queue = std.PriorityQueue(
    Gate,
    void,
    gateOrder
)

Your Gate:

const Gate = struct {
    tet_idx,
    face_idx,
    from_tet_idx,
    radius,
};

Meaning:

"Can I cross this face into this tetrahedron?"

The priority:

fn gateOrder(...)

sorts:

largest radius first

So:

large hole

   O

   |
   v

carve first
Step 5: Pop a gate and decide if the tetrahedron is exterior

This is the core.

You pop:

while(queue.pop()) |gate|

You get:

outside tet
       |
       |
       v
   candidate tet

Should we delete this?

The first checks:

if (self.tags.items[gate.tet_idx] == .outside)
    continue;

means:

already processed.

Then:

const tet =
 self.tri.tetrahedra.items[gate.tet_idx]

Get the actual cell.

Step 6: Check if crossing the cell hits the offset surface

This is the important geometry step.

The paper's idea:

Imagine every tetrahedron has a point:

tetrahedron
     |
     v

circumcenter


Connect:

previous circumcenter
          |
          |
          v
current circumcenter

Ask:

"Does this line cross the offset surface?"

Your code

Here:

const circumsphere =
    tet.circumsphere(self.tri)

gets:

tet center

Then:

const from_point

gets the previous center.

Then:

oracle.segmentOffsetIntersection(
    from_point,
    circumsphere.center,
    offset
)

This asks:

previous center
        |
        |
        ?
        |
        |
current center


Does distance(mesh)==offset happen here?

If yes:

if (...) |steiner|

you found the boundary.

Step 7: Insert Steiner point
Algorithm requirement

If the boundary cuts through a tetrahedron:

before:


+---------+
|         |
|   tet   |
|         |
+---------+


after:

+---------+
|    *    |
|   /|\   |
|  / | \  |
+---------+


You split the tetrahedron.

Your code

Here:

self.tri.addVertexTracked(
    a,
    steiner,
    &new_tets
)

This uses your Delaunay insertion.

Very nice design choice.

You don't need special alpha wrapping mesh operations.

Then:

for(new_tets.items)
    tags[idx]=.inside;

New tetrahedra start solid.

Then:

pushGatesIntoInsideTet()

continues the flood.

Step 8: If no boundary intersection, carve the tetrahedron

If:

segmentOffsetIntersection()

returns null:

The cell is probably exterior.

So:

self.tags.items[gate.tet_idx]
    = .outside;

This is the actual wrapping.

You are saying:

"This tetrahedron is air."

Step 9: Continue flooding neighbors

You do:

for(tet.faces())

Find neighbors:

neighborLocation()

Then:

queue.push()

Meaning:

outside cell

     |
     |
     v

neighbor candidate


Repeat until no gates remain.

Now: where your implementation differs from the real algorithm

The real algorithm has this predicate:

Does this tetrahedron intersect the object?

Your code has:

oracle.tetIntersectsMesh()

But your implementation is:

for triangle:
    for vertex:
        if vertex inside tet:
            return true

So your predicate is:

Does a triangle vertex lie inside the tetrahedron?

That is NOT the same.

Example:

       triangle


      ----------
     /          \
    /            \
   /              \
                  *



Triangle crosses tetrahedron:

       +-------+
       |       |
       |  /\   |
       | /  \  |
       +-------+


but:

no triangle vertex is inside
edges cross faces

Your code says:

false

Algorithm says:

true

That is the likely source of your failing enclosure test.

Your current implementation status
Algorithm step	Status
Delaunay tetrahedralization	✅ done
adjacency graph	✅ done
identify exterior hull	✅ done
priority flood	✅ done
circumcenter traversal	✅ done
Steiner refinement	✅ done
tag outside/inside	✅ done
extract boundary	✅ done
exact mesh intersection	❌ incomplete

The good news: your alpha wrapping architecture is correct. The failing part is not the flood, not the Delaunay, not the tagging. The weak point is the geometric oracle.

The next thing I would implement is not a better flood. It is:

triangle vs tetrahedron intersection

because that is the predicate that decides whether a cell is allowed to become outside. Once that is correct, your "strictly encloses mesh" test should become meaningful.
