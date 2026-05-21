# zig render
This project is a rendering library. It provides a set of tools for creating and managing Vulkan pipelines, shaders, and other rendering resources.

## PipelineManager
> Likely deprecated


The `PipelineManager` manages the registration of pipelines and manages the memeory of any data associated with them. An `Entry` in this manager can be thought of as an interface. The details of which can be found in the [PipelineManager.zig](./src/PipelineManager.zig) file.
The `ExpectedFunctions` enum describes which functions are expected on a type passed to `PipelineManager.Entry.create`. The function types returned by `ExpectedFunctions.funcType` are the expected function types for each variant. Variant names denote the name of the expected function on the type.
Any type passed to `create` must have default values for all of it's fields, even if that means they need to be undefined. An `initialize` function is also expected, which is what should be used to populate any `undefined` fields.
