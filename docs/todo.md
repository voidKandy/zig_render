
### Resource Management
[Vulkan resource management](https://docs.vulkan.org/tutorial/latest/Building_a_Simple_Engine/Engine_Architecture/04_resource_management.html)

When designing a resource management system, you’ll need to address several challenges:

* Loading and Unloading - Resources need to be loaded from disk and unloaded when no longer needed.
* Caching - Frequently used resources should be cached to avoid redundant loading.
* Reference Counting - Track how many objects are using a resource to know when it can be safely unloaded.
* Hot Reloading - Allow resources to be updated while the application is running (useful during development).
* Streaming - Load resources asynchronously to avoid blocking the main thread. It’s good to realize that "streaming" here is meant in terms of sending data from one location to another in chunks. It’s the same type of algorithm that might be familiar in networking or internet downloading, however, it only differs in the sense that it relates to transferring data between the system memory and the GPU memory.
* Memory Management - Efficiently allocate and deallocate memory for resources.

We already have the `ecs` module, which provides us with an interface for creating unique entities and associating data with each of them. Instead of utilizing a `Resource` class which all resources can derive behavior, we will need to just add types to the `ecs` (zig doesn't have builtin inheritance).


### Rendergraph
[Vulkan Rendergraph tutorial](https://docs.vulkan.org/tutorial/latest/Building_a_Simple_Engine/Engine_Architecture/05_rendering_pipeline.html)

Before work on the rendergraph can begin, we need to implement the use of the ECS module so that any resource can be backed by an entity at runtime.


### Material Meshes
TODO! Move this section to a .md file, this has been finished

`usemtl` is a keyword used in `.obj` files. I could utilize this to associate meshes parsed from files with materials and then look up those materials in my Resource manager to associate meshes with a given material ID that can be loaded into the descriptor set at draw time.
An `.mtl` parser should probably be written
+ [mtl format documentation](https://paulbourke.net/dataformats/mtl/)
+ [C++ 11 MTL parser](https://github.com/StefanJohnsen/WavefrontMTL/)

the `mtl_loader` module has now been written. It allows for extremely simple materials to be defined in `mtl` files; currently a material is simply an image file to be used as a texture. `assets/globals.mtl` is where all materials will be defined for now. This means all `.obj` files will need to use the `globals.mtl` file and reference materials defined there.
Currently, there is no way for the resource manager to interpret the `MtlFile` struct. This leads to the next issue: a stage based Resource management system. 
Stages: 
1. Loading & organiziing static assets at runtime
2. Changing those assets into Resources as they are currently referenced in `ResourceManager` (see the `IdentifierManager` fields)
3. Loading those Resources onto the GPU or wherever they may need to be

Steps 2 & 3 are already implemented. Step 1 just needs to be added.
I will start by just adding this logic directly inline in `initResources` in `bins/main.zig`. This logic can be moved into `core` once it is implemented.

Materials need to be referencable by string, currently they are referenced by u32. This way we can know which texture to load into a sampler per mesh at draw time.
This introduces an interesting problem. Should `ResourceManager` be refactored to keep strings of img names rather than u32? or should there be another manager on top of the resource manager that keeps track of texture's names by their corresponding resource id?

I began work on the above and quickly realized i need to change the approach to texture loading/uploading. 
The current implementation both reads from disk and uploads to the GPU. It then blocks via a semaphore to upload to the single texture to the GPU. This needs to be fixed. 
**READING:**
- [implementation details of a streaming based approach](https://erfan-ahmadi.github.io/blog/Nabla/imageupload)
- [a comprehensive blog on writing a vulkan renderer](https://zeux.io/2020/02/27/writing-an-efficient-vulkan-renderer/)
