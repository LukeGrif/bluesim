shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

// Procedural marine rope surface for the test rope (scripts/target_rope.gd).
// No textures: the strands, yarns and fibres are worked out from where a
// point is around the rope (0-1) and along it (metres), so the pattern runs
// on continuously from one physics piece to the next (along_offset).
//   construction 0: 3-strand twisted (laid) rope, strands with grooves
//                    between them and yarns twisted the other way
//                 1: braided cover (16 carriers, over-under), like double braid
//                 2: smooth (the old plain test rope)
// tracer: yarns of tracer_color in one strand (twisted) or two carriers
// (braided), like the coloured fleck or tracer in real marine rope.
// fuzz: loose fibres, for natural fibre (manila, hemp) or worn rope.

uniform vec4 base_color : hint_color = vec4(0.75, 0.06, 0.05, 1.0);
uniform vec4 tracer_color : hint_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float tracer = 0.0;
uniform float construction = 0.0;
uniform float radius = 0.0254;  // m
uniform float lay_length = 0.17;  // m for a strand to go once round (about 3.3 diameters)
uniform float along_offset = 0.0;  // m, where this mesh starts along the rope
uniform bool along_z = true;  // capsule pieces run along their Z axis, the fixed rod along Y
uniform float along_sign = 1.0;  // which way along that axis is further along the rope
uniform float fuzz = 0.0;

varying vec2 rope_uv;  // x: around the rope (0-1), y: along it (m)

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x),
		mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x), f.y);
}

// x: surface height 0-1, y: strand / carrier number, z: how far from a groove (0 in it)
vec3 pattern(vec2 uv) {
	if (construction < 0.5) {
		float a = 3.0 * (uv.x + uv.y / lay_length);  // three strands, right-hand lay
		float phase = fract(a);
		float bulge = sin(3.14159265 * phase);
		return vec3(sqrt(bulge), mod(floor(a), 3.0), bulge);
	} else if (construction < 1.5) {
		float s = uv.y / (lay_length * 1.6);
		float a1 = 8.0 * (uv.x + s);
		float a2 = 8.0 * (uv.x - s);
		// over-under: which family of carriers is on top in this cell
		bool first = mod(floor(a1) + floor(a2), 2.0) < 0.5;
		float phase = first ? fract(a1) : fract(a2);
		float bulge = sin(3.14159265 * phase);
		float id = first ? mod(floor(a1), 8.0) : 8.0 + mod(floor(a2), 8.0);
		return vec3(sqrt(bulge), id, bulge);
	}
	return vec3(0.5, 0.0, 1.0);
}

void vertex() {
	vec3 p = VERTEX;
	float along = along_sign * (along_z ? p.z : p.y);
	vec2 c = along_z ? p.xy : p.xz;
	rope_uv = vec2(atan(c.y, c.x) / 6.2831853 + 0.5, along + along_offset);
	// a lumpy outline: the strands of a laid rope stand out (about 7 % of the radius)
	VERTEX += NORMAL * radius * (construction < 0.5 ? 0.14 : 0.06) * (pattern(rope_uv).x - 0.5) * step(construction, 1.5);
}

void fragment() {
	vec3 pat = pattern(rope_uv);
	// fine detail fades out where it would be smaller than a pixel
	float detail = 1.0 - smoothstep(0.3, 1.0, fwidth(rope_uv.x * 24.0));

	// yarns twisted against the strands, and fibre-level noise
	float yarn = sin(6.2831853 * (24.0 * rope_uv.x - 1.3 * rope_uv.y / lay_length * 24.0 / 3.0));
	float fibre = noise(vec2(rope_uv.x * 120.0, rope_uv.y * 700.0));
	float hairs = noise(vec2(rope_uv.x * 40.0, rope_uv.y * 90.0));
	float plain = step(1.5, construction);
	float height = pat.x + (1.0 - plain) * detail * (0.12 * yarn + 0.1 * fibre);

	vec3 color = base_color.rgb;
	if (tracer > 0.5) {
		bool in_tracer = construction < 0.5 ? pat.y < 0.5 : (pat.y < 0.5 || abs(pat.y - 12.0) < 0.5);
		// tracer yarns: some of the yarns in that strand / carrier
		float fleck = construction < 0.5 ? step(0.2, yarn) : 1.0;
		if (in_tracer) {
			color = mix(color, tracer_color.rgb, fleck);
		}
	}
	float groove = mix(0.3, 1.0, smoothstep(0.0, 0.5, pat.z));
	float shade = groove * (0.88 + 0.24 * fibre * detail) * mix(1.0, 0.75 + 0.5 * hairs, fuzz);
	ALBEDO = color * mix(shade, 1.0, plain * 0.9);
	ROUGHNESS = 0.85;
	SPECULAR = 0.25;

	// bump from the surface height, using screen-space derivatives
	float h = height * radius * 0.35 * (1.0 - plain);
	vec3 dpdx = dFdx(VERTEX);
	vec3 dpdy = dFdy(VERTEX);
	float dhdx = dFdx(h);
	float dhdy = dFdy(h);
	vec3 r1 = cross(dpdy, NORMAL);
	vec3 r2 = cross(NORMAL, dpdx);
	float det = dot(dpdx, r1);
	vec3 grad = sign(det) * (dhdx * r1 + dhdy * r2);
	NORMAL = normalize(abs(det) * NORMAL - grad);
}
