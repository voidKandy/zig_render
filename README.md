# Untitle zig game engine
## Main Graphics Pipeline
The main graphics pipeline can render 'meshes' from .obj files and .mtl files respectively. [This binary](bins/main.zig) has an example of how this is declared. Vertex and Index data are stored in SSBOs rather than using vulkan's builtin vertex and index buffers. 
One 'mesh' is really just a collection of submesh ranged that describe a range of vertices/indices that are asoociated with a given material. Materials are uploaded one gpu texture per .mtl file; an .mtl file will point at some images and the engine will upload one texture that combines all textures in that .mtl file. 

## Screenshots
<img width="975" height="711" alt="Screenshot 2026-06-04 at 8 04 33 PM" src="https://github.com/user-attachments/assets/981336b9-0b59-4443-a2cd-65888600d6cc" />
As you can see, meshes can be assoicated with arbitrary materials and moved via the gui
<img width="998" height="753" alt="Screenshot 2026-06-04 at 8 04 48 PM" src="https://github.com/user-attachments/assets/8062d90b-c047-4efa-bf81-4ab7635ee277" />

