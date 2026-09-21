#version 460
#extension GL_EXT_debug_printf : enable
// run export DEBUG_PRINTF_TO_STDOUT=true to see
// unset DEBUG_PRINTF_TO_STDOUT to disable

layout(location = 0) in vec2 inPosition;
layout(location = 1) in vec2 inColor;



layout (set = 0, binding = 0) readonly uniform CameraData {
    mat4 view;
    mat4 proj;
} camera_Ubo;



void main()
{

}
