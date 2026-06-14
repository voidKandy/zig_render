# Alpha wrapping

[](https://inria.hal.science/hal-03688637v1/file/alpha-wrapping-author.pdf)

The core loop has about five key terms worth unpacking:
**Delaunay triangulation** - you fill all of 3D space with tetrahedra (4-sided pyramids) whose vertices are your input points, with the property that no point sits inside any tetrahedron's circumsphere (the sphere that exactly touches all 4 corners). It's a specific way of tiling space that tends to produce well-shaped, non-slivery tetrahedra.

**Carving** - you start with the convex hull of the input (imagine shrink-wrapping a box around everything) and then eat inward, removing tetrahedra from the outside one by one. The key constraint is you're only allowed to remove a tetrahedron if you can fit a ball of radius α through the face you'd enter from without hitting the input. This is what prevents carving into thin gaps or small holes.

**a-traversable** - a face between two tetrahedra is traversable if the smallest empty ball that fits through it has radius ≥ α. It's the gate condition for carving: if the gap is too tight, you can't pass through, and whatever is on the other side stays enclosed.

**Offset surface** - instead of placing output vertices directly on the input, you place them at distance δ away from it. This is the Iδ surface in the paper. It's what guarantees the output strictly encloses the input even in degenerate cases ; your mesh vertices literally cannot be closer than δ to the input geometry.

**Refinement** - when a boundary tetrahedron (one on the edge between carved-outside and uncarved-inside) intersects the input geometry, you can't just carve it away. Instead you insert a new Steiner point on the offset surface to split it into smaller tetrahedra, pushing the boundary inward more carefully. This is how the mesh conforms to the input shape.

**Rule R1 vs R2** - the two ways to pick where to insert that Steiner point. R1 shoots a ray along the Voronoi edge (the line connecting two adjacent circumcenters) and intersects it with the offset surface - this tends to produce well-shaped triangles. R2 is the fallback: project the circumcenter directly onto the nearest point on the input, then lift it out to the offset surface. R1 is preferred because R2 can create skewed elements.

The overall loop is then: carve where you can → when you can't because a tetrahedron intersects the input, refine it → repeat until no boundary tetrahedra intersect the input and all boundary faces are non-traversable.
