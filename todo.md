# Todo
- [ ] move `tools/Camera.zig` into the engine itself 
- [ ] Figure out mesh initialization so that materials can be associated with meshes through data and not through hard coding (`bins/main.initMeshes`)
- [ ] Move Descriptor initialization to the engine itself (fix the `BAD` message in `bins/main.initDescriptors`)

### Material Meshes
`usemtl` is a keyword used in `.obj` files. I could utilize this to associate meshes parsed from files with materials and then look up those materials in my Resource manager to associate meshes with a given material ID that can be loaded into the descriptor set at draw time.
An `.mtl` parser should probably be written
+ [mtl format documentation](https://paulbourke.net/dataformats/mtl/)
+ [C++ 11 MTL parser](https://github.com/StefanJohnsen/WavefrontMTL/)
