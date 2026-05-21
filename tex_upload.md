# Texture Uploads
> How texture uploads should work 

## The problem with the current approach
Currently, the way textures are uploaded. *One* function handles both loading from a file and uploading to the GPU. The uploading also blocks via a semaphore until the *single* texture is uploaded to the GPU. It should be obvious why this doesn't scale.

## Descriptor indexing
A possible solution is Descriptor Indexing. This is an approach where instead of binding individual descriptor sets per texture, we bind one massive descriptor set (which is essentially just an array of descriptor sets) and then index into that in our shaders. This way sets only need to be bound *once*. 

### Update-after-bind (UAB)
UAB is a major feature of descriptor indexing. Usually, in vulkan, you have to create a `vkDescriptorSet` and then update it with all other descriptors before calling `vkCmdBindDescriptorSet`. In this paradigm, the descriptor set *cannot* be updated until the GPU is done using it. UAB allows us to update descriptors at *any* time as long as the GPU isn't currently accessing it. For example, with UAB a descriptor can be updated while a descriptor set is bound to a command buffer, which is not possible without UAB. With UAB we can also update sets from multiple threads.
Details regarding how to enable UAB are in the *descriptor indexing* article.

### Non-Uniform Indexing (NU Indexing)
NU Indexing is another boon of utilizing descriptor indexing. Vulkan offers other approaches to indexing: 
+ **Constant Indexing** - "magic numbers" all over our shader code to reference specific textures and descriptor sets
+ **Dynamically Uniform Indexing** - allows us to use non-constant indexes into textures and descriptor sets, provided the indexes are *dynamically uniform*

**NU Indexing** allows us to index without restriction, provided we notify the compiler. Normally, drivers and hardware can assume that the dynamically uniform guarantee holds, and optimize for that case. If we use the `nonuniformEXT` decoration in `GL_EXT_nonuniform_qualifier` we can let the compiler know that the guarantee does not necessarily hold, and the compiler will deal with it in the most efficient way possible for the target hardware. The rationale for having to annotate like this is that driver compiler backends would be forced to be more conservative than necessary if applications were not required to use `nonuniformEXT`.

### Texture Atlas
Accessing arbitrary textures in a draw call is not a new problem, and there are many different ways to solve it. One such way is with a **texture atlas**, this approach takes multiple textures and packs them into a single texture resource, which is then sampled according to whatever individual texture needs to be accessed. 
There are some problems with the atlas approach: 
+ Mip-mapping is increasingly hard to implement
+ anistropic filtering is basically impossible
+ Any sampler addressing other that `CLAMP_TO_EDGE` is very difficult to implement
+ Locked into a single texture format

**NU Indexing** solves all these problems.

### what does dynamically uniform mean?
+ *invocation group* (IG) - a set of threads (invocations) which work together to perform some task. In graphics pipelines, the IG is all threads which are spawned as a part of a *single* draw command. In compute pipelines, the IG is a single workgroup
+ *dynamically uniform* - an expression is considered dynamically uniform if all invocations in an IG have the same value. This does not mean "as long as the value is uniform in a subgroup it is dynamically uniform." In some cases, a value can be subgroup uniform but not dynamically uniform. In other words, just because all threads in a subgroup might have the same value that doesn't mean all subgroups in a workgroup will. So, we can use `nonuiformEXT` to flag to the compiler that we really only care about subgroup uniformity. This, of course means that we cannot consider our value **dynamically uniform**

### Sample shader code using descriptor indexing
Here is an example of rendering 64 unique textures in a single draw call with the use of non-uniform indexing.
```glsl
#extension GL_EXT_nonuniform_qualifier : require
layout(set = 0, binding = 0) uniform texture2D Textures[];
layout(set = 1, binding = 0) uniform sampler ImmutableSampler;
out_frag_color = texture(nonuniformEXT(sampler2D(Textures[in_texture_index], ImmutableSampler)), in_uv);
```
The key thing here is `nonuniformEXT`, which allows us to index into an array of resources where the index is *not* dynamically* uniform. As a reminder, in graphics, *dynamically uniform* means that the index is the same across all threads spawned by a draw command. In this case, each threads is indexing into one of the 64 textures; so of course the indices are not the same.

## Implementing Descriptor indexing
### 1 Enabling Descriptor Indexing
First, we need to make sure our device has the capabilities. I've added a new function in `vulkan_init.LogicalDevice` to quickly initialize `vk.PhysicalDeviceDescriptorIndexingFeatures`.

### 2 Create Layout
Next, we need to actually create the descriptor set layout. The example I am going off of uses an unbounded descriptor array for it's texture resources, so I will do the same. Keep in mind **vulkan requires that an unbounded array is the last descriptor in it's set**. This means we need to tell vulkan that we have an unbounded array in our descriptor set when we create the `vk.DescriptorSetLayout`, we do this by using `vk.DescriptorSetLayoutBindingFlagsCreateInfo` as the `pNext` in the `vk.DescriptorSetLayoutCreateInfo`. `vk.DescriptorSetLayoutBindingFlagsCreateInfo` has an array of flags for each binding in the descriptor set, any descriptor which can be an unbounded array must have the flag `vk.DESCRIPTOR_BINDING_VARIABLE_DESCRIPTOR_COUNT_BIT` at their index in the flags array. For example, if binding 3 is an unbounded array, descriptor, then `vk.DescriptorSetLayoutBindingFlagsCreateInfo.pBindingFlags[2]` must have `vk.DESCRIPTOR_BINDING_VARIABLE_DESCRIPTOR_COUNT_BIT`.
When one of the descriptors is an unbounded array, the `descriptorCount` member of `vk.DescriptorSetLayoutBinding` is the upper bound on the size of that array. So technically the desccriptor *is not* unbounded.

I have made changes to `main.initDescriptors` to reflect how this might be implemented. I have done this naively, the descriptors will need to be figured out.

Adjustments have been made to `descriptor.Allocator.allocate` to reflect the new need for using `vk.DescriptorSetVariableDescriptorCountAllocateInfo` as `pNext` of `vk.DescriptorSetAllocateInfo`.


## Copying from [ogldev](https://github.com/emeiri/ogldev/blob/0d4b19d7fe5a2c53f85ec080d7b0d6d91386097c/Vulkan/Tutorial29/tutorial29.cpp#L46)
I have decided to copy the implementation at the link above. 
The implementation lives in `pipelines/DescriptorIndexing.zig` this is horribly named and should be changed.
A new field was added to `VulkanEngine` called `pipeline`, which is of type `pipelines/DescriptorIndexing.zig`. `VulkanEngine` also got a new function called `initPipeline` that initializes this field and creates the pool and sets and also updates the sets. I have not figured out how to translate the previous `BoundDescriptor` to this new system.
The main issue right now is tranlsating from `main.initDescriptors` to use the new method outlined in `DescriptorIndexing`.
+ One thing I've noticed is that the new implementation at `DescriptorIndexing` doesn't utilize `DescriptorBindingFlags` at all...
+ IMGUI HAS BEEN COMMENTED OUT 


### References
+ [descriptor indexing](https://docs.vulkan.org/samples/latest/samples/extensions/descriptor_indexing/README.html)
+ [subgroups](https://docs.vulkan.org/guide/latest/subgroups.html)
+ [video tutorial](https://www.youtube.com/watch?v=GsnOWtptPM0)
+ [pipeline class implementation w/ descriptor indexing](https://github.com/emeiri/ogldev/blob/VULKAN_26/Vulkan/VulkanCore/Source/graphics_pipeline_v3.cpp)
+ [descriptor indexing guide](https://gist.github.com/NotAPenguin0/284461ecc81267fa41a7fbc472cd3afe)
+ [Uploading Textures to GPU - The Good Way](https://erfan-ahmadi.github.io/blog/Nabla/imageupload)
+ [helpful reddit post](https://www.reddit.com/r/vulkan/comments/17uznmy/how_do_you_handle_multiple_textures/)
