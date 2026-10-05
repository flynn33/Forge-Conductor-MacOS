#include <metal_stdlib>
using namespace metal;

struct ChipInstance { float4 rect; float4 color; float4 properties; };
struct ChipUniforms { float4 viewport; float4 options; };
struct ChipVertex {
    float4 position [[position]];
    float2 uv;
    float2 size;
    float4 color;
    float4 properties;
};

vertex ChipVertex compute_chip_vertex(uint vertexID [[vertex_id]], uint instanceID [[instance_id]],
                                     const device ChipInstance *instances [[buffer(0)]],
                                     constant ChipUniforms &uniforms [[buffer(1)]]) {
    constexpr float2 points[6] = { float2(0,0), float2(1,0), float2(0,1),
                                  float2(1,0), float2(1,1), float2(0,1) };
    ChipInstance item = instances[instanceID];
    float2 local = (points[vertexID] - 0.5) * item.rect.zw;
    float angle = item.properties.w;
    float2 point = item.rect.xy + float2(local.x*cos(angle)-local.y*sin(angle),
                                       local.x*sin(angle)+local.y*cos(angle));
    ChipVertex out;
    out.position = float4(point.x / uniforms.viewport.x * 2 - 1,
                          1 - point.y / uniforms.viewport.y * 2, 0, 1);
    out.uv = points[vertexID]; out.size = item.rect.zw;
    out.color = item.color; out.properties = item.properties;
    return out;
}

float chip_hash(float2 p) { return fract(sin(dot(p,float2(127.1,311.7)))*43758.5453); }
float chip_chamfer(float2 uv, float2 size) {
    float2 p = abs((uv - 0.5) * size);
    float2 halfSize = size * 0.5;
    float corner = min(7.0, max(0.55, min(size.x, size.y) * 0.021));
    return min(min(halfSize.x-p.x, halfSize.y-p.y),
               (halfSize.x+halfSize.y-p.x-p.y-corner) * 0.7071);
}
float chip_material_alpha(float2 uv, float channel, texture2d<float> cpuMaterial,
                          texture2d<float> gpuMaterial, sampler materialSampler) {
    float inside = step(0.0,uv.x)*step(0.0,uv.y)*step(uv.x,1.0)*step(uv.y,1.0);
    float coverage = channel < 0.5 ? cpuMaterial.sample(materialSampler,uv).a
                                   : gpuMaterial.sample(materialSampler,uv).a;
    return coverage*inside;
}

fragment float4 compute_chip_fragment(ChipVertex in [[stage_in]],
                                     const device float *activity [[buffer(0)]],
                                     constant ChipUniforms &uniforms [[buffer(1)]],
                                     texture2d<float> cpuMaterial [[texture(0)]],
                                     texture2d<float> gpuMaterial [[texture(1)]],
                                     sampler materialSampler [[sampler(0)]]) {
    int kind = int(in.properties.x);
    float2 p = in.uv * in.size;
    float seed = in.properties.z;
    float3 color = in.color.rgb;
    float alpha = in.color.a;
    float grain = chip_hash(floor(p * float2(1.4,3.1)) + seed);
    float edge = chip_chamfer(in.uv, in.size);
    if (kind == 11) {
        // The immutable sRGB materials contain no activity light. Upload is straight alpha;
        // the existing source-alpha pipeline applies coverage exactly once.
        return in.properties.z < 0.5 ? cpuMaterial.sample(materialSampler,in.uv)
                                     : gpuMaterial.sample(materialSampler,in.uv);
    } else if (kind == 10) {
        // The shadow follows transparent package cutouts, never the surrounding quad.
        float2 bodySize = max(in.size-float2(10),float2(1));
        float2 materialUV = (p-float2(5))/bodySize;
        float2 spread = float2(2.4)/bodySize;
        float coverage = 0;
        for (int y=-1;y<=1;y++) {
            for (int x=-1;x<=1;x++) {
                float weight = x == 0 && y == 0 ? 0.20 : 0.10;
                coverage += weight*chip_material_alpha(materialUV+float2(x,y)*spread,
                                                       in.properties.z,cpuMaterial,gpuMaterial,materialSampler);
            }
        }
        alpha *= coverage;
        color = float3(0);
    } else if (kind == 9) {
        float radius = min(10.0,min(in.size.x,in.size.y)*0.08);
        float2 q = abs((in.uv-0.5)*in.size)-in.size*0.5+radius;
        float boundary = length(max(q,float2(0)))+min(max(q.x,q.y),0.0)-radius;
        alpha *= 1-smoothstep(-0.35,0.35,boundary);
        float2 radial = (in.uv-float2(0.5,0.53))/float2(0.68,0.88);
        float field = exp(-2.8*dot(radial,radial));
        float fieldGrain = chip_hash(floor(in.uv*float2(437,563))+seed);
        color *= 0.78+field*0.25+(fieldGrain-0.5)*0.035;
        color += field*float3(0.0015,0.0035,0.0055);
        float border = 1-smoothstep(0.25,0.80,abs(boundary+0.70));
        color += border*float3(0.006,0.012,0.016);
    } else if (kind == 0 || kind == 1 || kind == 3 || kind == 8) {
        float detailScale = clamp(min(in.size.x,in.size.y)/156.0,0.16,2.5);
        float bevelWidth = max(0.45,1.45*detailScale);
        alpha *= smoothstep(-0.35,0.45,edge);
        float rim = 1 - smoothstep(bevelWidth*0.35,bevelWidth*1.65,edge);
        float topLight = 0.76 + (1-in.uv.y)*0.35;
        color *= topLight + (grain-0.5) * (kind == 1 ? 0.18 : 0.12);
        if (kind == 1) {
            float bevelDistance = edge/bevelWidth-0.85;
            float bevel = exp(-2.8*bevelDistance*bevelDistance);
            float brush = chip_hash(floor(in.uv * float2(173,947)) + seed);
            float machining = sin(in.uv.y*1700.0+seed)*0.012;
            float innerShadow = smoothstep(bevelWidth*2.3,bevelWidth*5.2,edge);
            float directional = 0.58 + (1-in.uv.y)*0.29 + (1-in.uv.x)*0.13;
            color *= (0.35 + bevel*0.68 + (brush-0.5)*0.075 + machining)
                   * (1-innerShadow*0.31) * directional;
            color += rim * float3(0.14,0.20,0.25) * (0.40 + directional*0.65);
            float engraved = 1-smoothstep(0.04,0.10,abs(edge/bevelWidth-2.05));
            color += engraved*float3(0.014,0.023,0.029);
        } else {
            color += rim * float3(0.045,0.08,0.10);
            if (kind == 0 || kind == 3) {
                float2 field = in.uv * float2(31,27) + float2(seed*0.23,seed*0.17);
                float2 tile = floor(field);
                float2 local = fract(field);
                float choice = chip_hash(tile + seed);
                float routeY = 0.22 + 0.56*chip_hash(tile+seed+3.0);
                float routeX = 0.20 + 0.60*chip_hash(tile+seed+7.0);
                float horizontal = (1-smoothstep(0.012,0.030,abs(local.y-routeY)))
                                 * step(0.13,local.x) * (1-step(0.55+choice*0.32,local.x));
                float vertical = (1-smoothstep(0.012,0.030,abs(local.x-routeX)))
                               * step(routeY,local.y) * (1-step(0.88,local.y));
                float circuit = (horizontal+vertical) * step(0.61,choice);
                float2 padCenter = float2(routeX,routeY);
                float pad = (1-smoothstep(0.55,1.0,length((local-padCenter)/float2(0.12,0.085))))
                          * (1-step(0.23,choice));
                float material = chip_hash(floor(in.uv*float2(11,13))+seed);
                color *= 0.80 + material*0.18;
                color += float3(0.009,0.018,0.023)*circuit + float3(0.022,0.027,0.025)*pad;
                float fineEtch = 1-smoothstep(0.018,0.042,abs(fract(in.uv.x*83.0)-0.5));
                color += fineEtch * float3(0.0015,0.003,0.004);
                if (kind == 3) {
                    color *= 0.43 + smoothstep(bevelWidth*0.4,bevelWidth*3.5,edge)*0.57;
                }
            }
        }
    } else if (kind == 2) {
        float rim = min(min(p.x,in.size.x-p.x),min(p.y,in.size.y-p.y));
        color *= 0.6 + (1-in.uv.x)*0.8 + grain*0.13;
        color += float3(0.24,0.19,0.09) * (1-smoothstep(0.4,1.1,rim));
    } else if (kind == 4 || kind == 12) {
        int region = int(in.properties.y);
        float raw = region >= 0 && region < 272 ? activity[region] : -1;
        float value = clamp(raw,0.0,1.0);
        // Native reference-bank grid dimensions share the existing instance ABI.
        int metadata = max(int(in.properties.z),1);
        int columns = max(metadata % 32,1);
        int rows = max((metadata / 32) % 32,1);
        int bank = metadata / 1024;
        float2 grid = in.uv * float2(columns,rows);
        float2 cell = floor(grid);
        float2 local = fract(grid);
        float2 aa = min(fwidth(grid)*0.65,float2(0.20));
        float mask = smoothstep(0.11-aa.x,0.11+aa.x,local.x)
                   * (1-smoothstep(0.85-aa.x,0.85+aa.x,local.x))
                   * smoothstep(0.12-aa.y,0.12+aa.y,local.y)
                   * (1-smoothstep(0.80-aa.y,0.80+aa.y,local.y));
        float random = chip_hash(cell+float2(bank*19+region*3,bank*7+region));
        float density = smoothstep(random-0.045,random+0.045,0.12+value*0.80);
        float2 center = float2(0.28+0.44*chip_hash(float2(bank+region,17)),
                               0.28+0.44*chip_hash(float2(bank+region,29)));
        float2 distance = (in.uv-center)/float2(0.22,0.19);
        float halo = exp(-0.8*dot(distance,distance));
        float whiteCore = exp(-1.5*dot(distance,distance));
        float energy = pow(value,0.65);
        float3 tint = in.color.rgb;
        if (region >= 256 && kind != 12) {
            // These simultaneous bank hues are illustrative aggregate regions, not
            // measured GPU topology. Activity changes hue within each fixed bank family.
            float3 blue = float3(0.0331,0.4125,1.0);
            float3 cyan = float3(0.0331,0.7157,1.0);
            float3 mint = float3(0.0382,0.7157,0.5271);
            float3 violet = float3(0.3613,0.1779,1.0);
            if (bank == 1 || bank == 5) {
                tint = mix(blue,cyan,smoothstep(0.15,0.62,value));
            } else if (bank == 2 || bank >= 8) {
                tint = mix(blue,violet,0.20+0.75*value);
            } else {
                tint = mix(tint,mint,value*0.10);
            }
        }
        float coreEnergy = pow(energy,1.6);
        float3 cellColor = tint*(0.22+1.20*energy)*(0.55+0.95*halo)*mix(0.10,1.0,density)
                         + whiteCore*coreEnergy*float3(1.8,2.052,2.16);
        float cellAlpha = mask*(0.35+0.65*energy);
        // A local glow occupies only this region's gaps, keeping the emitting tiles
        // crisp while allowing the same actual activity to illuminate nearby material.
        float2 tileDistance = local-0.5;
        float localFalloff = exp(-5.0*dot(tileDistance,tileDistance));
        float bloomAlpha = (1-mask)*(region >= 256
            ? energy*(0.12+0.25*coreEnergy*halo*localFalloff)
            : 0.35*coreEnergy*halo*localFalloff);
        float3 bloomColor = tint*(0.30+0.85*energy) + whiteCore*coreEnergy*float3(0.40,0.70,1.0);
        color = (cellColor*cellAlpha+bloomColor*bloomAlpha)/max(cellAlpha+bloomAlpha,0.0001);
        alpha *= cellAlpha+bloomAlpha;
        if (raw == 0) { alpha = 0; }
        if (raw < 0) {
            color = float3(0.055,0.066,0.075);
            alpha = in.color.a*mask*0.16;
        }
        float rim = min(min(p.x,in.size.x-p.x),min(p.y,in.size.y-p.y));
        color *= region < 256 ? uniforms.options.y : uniforms.options.z;
        alpha *= smoothstep(0.0,0.55,rim);
    } else if (kind == 5) {
        float radius = length((in.uv-0.5)*2);
        alpha *= 1-smoothstep(0.65,1.0,radius);
        color *= 0.45+1.25*exp(-8.0*radius*radius);
        color += float3(0.65,0.95,1.0)*0.40*exp(-30.0*radius*radius);
    } else if (kind == 6) {
        alpha *= 0.75;
    } else if (kind == 7) {
        float2 local = (in.uv-0.5)*2;
        float radius = length(local);
        alpha *= exp(-5.5*radius*radius);
        color = mix(in.color.rgb,float3(0.76,0.96,1),exp(-32*radius*radius));
    }
    if (uniforms.options.x > 0.5 && (kind == 4 || kind == 12)) { color *= 1.35; }
    return float4(color,alpha);
}
