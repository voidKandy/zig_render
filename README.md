# Untitle zig game engine
## Main Graphics Pipeline
The main graphics pipeline can render 'meshes' from .obj files and .mtl files respectively. [This binary](bins/main.zig) has an example of how this is declared. Vertex and Index data are stored in SSBOs rather than using vulkan's builtin vertex and index buffers. 
One 'mesh' is really just a collection of submesh ranged that describe a range of vertices/indices that are asoociated with a given material. Materials are uploaded one gpu texture per .mtl file; an .mtl file will point at some images and the engine will upload one texture that combines all textures in that .mtl file. 

### Screenshots
<img width="975" height="711" alt="Screenshot 2026-06-04 at 8 04 33 PM" src="https://github.com/user-attachments/assets/981336b9-0b59-4443-a2cd-65888600d6cc" />
As you can see, meshes can be assoicated with arbitrary materials and moved via the gui
<img width="998" height="753" alt="Screenshot 2026-06-04 at 8 04 48 PM" src="https://github.com/user-attachments/assets/8062d90b-c047-4efa-bf81-4ab7635ee277" />

## Compute Pipeline
Just a recreation of vulkan guide's implementation but reworked for the architecture of this engine. It provides a nice template of how to organize compute shaders.

### Screenshots
<img width="1394" height="961" alt="Screenshot 2026-06-04 at 8 17 27 PM" src="https://github.com/user-attachments/assets/393fae4c-0657-4f29-b1c5-fbd8e728261c" />
Background created by a compute shader can be adjusted in real time.
<img width="1302" height="862" alt="Screenshot 2026-06-04 at 8 18 16 PM" src="https://github.com/user-attachments/assets/6da60b82-1b3f-4807-92d5-5d64aef16de3" />

