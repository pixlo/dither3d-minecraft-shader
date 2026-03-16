#version 330 compatibility

uniform sampler2D gtexture;
uniform sampler2D lightmap;

in vec2 texCoord;
in vec2 lightCoord;
in vec4 vertexColor;

void main() {
    /* DRAWBUFFERS:0 */
    vec4 color = texture(gtexture, texCoord) * vertexColor;
    color *= texture(lightmap, lightCoord);

    if (color.a < 0.1) discard;

    gl_FragData[0] = vec4(color.rgb, 1.0);
}
