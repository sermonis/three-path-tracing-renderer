precision highp float;
precision highp int;
precision highp sampler2D;

uniform float uCameraUnderWater;
uniform vec3 uSunDirection;

uniform mat4 uShortBoxInvMatrix;
uniform mat4 uTallBoxInvMatrix;

#include <pathtracing_uniforms_and_defines>

#include <pathtracing_calc_fresnel_reflectance>

uniform sampler2D t_PerlinNoise;


#include <pathtracing_skymodel_defines>

#define N_QUADS 4
#define N_BOXES 2
#define N_OPENCYLINDERS 4


//-----------------------------------------------------------------------

struct Ray { vec3 origin; vec3 direction; };
struct OpenCylinder { float radius; vec3 pos1; vec3 pos2; vec3 emission; vec3 color; int type; };
struct Quad { vec3 normal; vec3 v0; vec3 v1; vec3 v2; vec3 v3; vec3 emission; vec3 color; int type; };
struct Box { vec3 minCorner; vec3 maxCorner; vec3 emission; vec3 color; int type; };
struct Intersection { vec3 normal; vec3 emission; vec3 color; vec2 uv; int type; };

OpenCylinder openCylinders[N_OPENCYLINDERS];
Quad quads[N_QUADS];
Box boxes[N_BOXES];


#include <pathtracing_random_functions>

#include <pathtracing_sphere_intersect>

#include <pathtracing_opencylinder_intersect>

#include <pathtracing_plane_intersect>

#include <pathtracing_quad_intersect>

#include <pathtracing_box_intersect>

#include <pathtracing_physical_sky_functions>


//---------------------------------------------------------------------------------------------------------
float DisplacementBoxIntersect( vec3 minCorner, vec3 maxCorner, Ray r )
//---------------------------------------------------------------------------------------------------------
{
	vec3 invDir = 1.0 / r.direction;
	vec3 tmin = (minCorner - r.origin) * invDir;
	vec3 tmax = (maxCorner - r.origin) * invDir;
	
	vec3 real_min = min(tmin, tmax);
	vec3 real_max = max(tmin, tmax);
	
	float minmax = min( min(real_max.x, real_max.y), real_max.z);
	float maxmin = max( max(real_min.x, real_min.y), real_min.z);
	
	// early out
	if (minmax < maxmin) return INFINITY;
	
	if (maxmin > 0.0) // if we are outside the box
	{
		return maxmin;	
	}
		
	if (minmax > 0.0) // else if we are inside the box
	{
		return minmax;
	}
				
	return INFINITY;
}


// SEA
/* Credit: some of the following ocean code is borrowed from https://www.shadertoy.com/view/Ms2SD1 posted by user 'TDM' */

#define SEA_HEIGHT     1.0 // this is how many units from the top of the ocean bounding box
#define SEA_FREQ       1.5 // wave density: lower = spread out, higher = close together
#define SEA_CHOPPY     2.0 // smaller beachfront-type waves, they travel in parallel
#define SEA_SPEED      0.15 // how quickly time passes
#define OCTAVE_M   mat2(1.6, 1.2, -1.2, 1.6);

float hash( vec2 p )
{
	float h = dot(p,vec2(127.1,311.7));	
    	return fract(sin(h)*43758.5453123);
}

float noise( in vec2 p )
{
	vec2 i = floor( p );
	vec2 f = fract( p );	
	vec2 u = f*f*(3.0-2.0*f);
	return -1.0+2.0*mix( mix( hash( i + vec2(0.0,0.0) ), 
		     hash( i + vec2(1.0,0.0) ), u.x),
		mix( hash( i + vec2(0.0,1.0) ), 
		     hash( i + vec2(1.0,1.0) ), u.x), u.y);
}

float sea_octave( vec2 uv, float choppy )
{
	uv += noise(uv);        
	vec2 wv = 1.0 - abs(sin(uv));
	vec2 swv = abs(cos(uv));    
	wv = mix(wv, swv, clamp(wv, 0.0, 1.0));
	return pow(1.0 - pow(wv.x * wv.y, 0.65), choppy);
}

float getOceanWaterHeight( vec3 p )
{
	p.x *= 0.001;
	p.z *= 0.001;
	float freq = SEA_FREQ;
	float amp = SEA_HEIGHT;
	float choppy = SEA_CHOPPY;
	float sea_time = uTime * SEA_SPEED;
	
	vec2 uv = p.xz; uv.x *= 0.75;
	float d, h = 0.0;

	d =  sea_octave((uv + sea_time) * freq, choppy);
	d += sea_octave((uv - sea_time) * freq, choppy);
	h += d * amp;        
	
	return 50.0 * h - 10.0;
}

float getOceanWaterHeight_Detail( vec3 p )
{
	p.x *= 0.001;
	p.z *= 0.001;
	float freq = SEA_FREQ;
	float amp = SEA_HEIGHT;
	float choppy = SEA_CHOPPY;
	float sea_time = uTime * SEA_SPEED;
	
	vec2 uv = p.xz; uv.x *= 0.75;
	float d, h = 0.0;    
	for(int i = 0; i < 4; i++)
	{        
		d =  sea_octave((uv + sea_time) * freq, choppy);
		d += sea_octave((uv - sea_time) * freq, choppy);
		h += d * amp;        
		uv *= OCTAVE_M; freq *= 1.9; amp *= 0.22;
		choppy = mix(choppy, 1.0, 0.2);
	}
	return 50.0 * h - 10.0;
}


// CLOUDS
/* Credit: some of the following cloud code is borrowed from https://www.shadertoy.com/view/XtBXDw posted by user 'valentingalea' */

#define THICKNESS      25.0
#define ABSORPTION     0.45
#define N_MARCH_STEPS  12
#define N_LIGHT_STEPS  3

float noise3D( in vec3 p )
{
	return texture(t_PerlinNoise, p.xz).x;
}

const mat3 m = 1.21 * mat3( 0.00,  0.80,  0.60,
                    -0.80,  0.36, -0.48,
		    -0.60, -0.48,  0.64 );

float fbm( vec3 p )
{
	float t;
	float mult = 2.0;
	t  = 1.0 * noise3D(p);   p = m * p * mult;
	t += 0.5 * noise3D(p);   p = m * p * mult;
	t += 0.25 * noise3D(p);
	
	return t;
}

float cloud_density( vec3 pos, float cov )
{
	float dens = fbm(pos * 0.002);
	dens *= smoothstep(cov, cov + 0.05, dens);

	return clamp(dens, 0.0, 1.0);	
}

float cloud_light( vec3 pos, vec3 dir_step, float cov )
{
	float T = 1.0; // transmitance
    	float dens;
    	float T_i;
	
	for (int i = 0; i < N_LIGHT_STEPS; i++) 
	{
		dens = cloud_density(pos, cov);
		T_i = exp(-ABSORPTION * dens);
		T *= T_i;
		pos += dir_step;
	}

	return T;
}

vec4 render_clouds( Ray eye, vec3 p, vec3 sunDirection )
{
	float march_step = THICKNESS / float(N_MARCH_STEPS);
	vec3 pos = p + vec3(uTime * -3.0, uTime * -0.5, uTime * -2.0);
	vec3 dir_step = eye.direction / clamp(eye.direction.y, 0.3, 1.0) * march_step;
	vec3 light_step = sunDirection * 5.0;
	
	float covAmount = (sin(mod(uTime * 0.1, TWO_PI))) * 0.5 + 0.5;
	float coverage = mix(1.0, 1.5, clamp(covAmount, 0.0, 1.0));
	float T = 1.0; // transmitance
	vec3 C = vec3(0); // color
	float alpha = 0.0;
	float dens;
	float T_i;
	float cloudLight;
	
	for (int i = 0; i < N_MARCH_STEPS; i++)
	{
		dens = cloud_density(pos, coverage);

		T_i = exp(-ABSORPTION * dens * march_step);
		T *= T_i;
		cloudLight = cloud_light(pos, light_step, coverage);
		C += T * cloudLight * dens * march_step;
		C = mix(C * 0.95, C, clamp(cloudLight, 0.0, 1.0));
		alpha += (1.0 - T_i) * (1.0 - alpha);
		pos += dir_step;
	}
	
	return vec4(C, alpha);
}

float checkCloudCover( vec3 sunDirection, vec3 p )
{
	float march_step = THICKNESS / float(N_MARCH_STEPS);
	vec3 pos = p + vec3(uTime * -3.0, uTime * -0.5, uTime * -2.0);
	vec3 dir_step = sunDirection / clamp(sunDirection.y, 0.001, 1.0) * march_step;
	
	float covAmount = (sin(mod(uTime * 0.1, TWO_PI))) * 0.5 + 0.5;
	float coverage = mix(1.0, 1.5, clamp(covAmount, 0.0, 1.0));
	float alpha = 0.0;
	float dens;
	float T_i;
	
	for (int i = 0; i < N_MARCH_STEPS; i++)
	{
		dens = cloud_density(pos, coverage);
		T_i = exp(-ABSORPTION * dens * march_step);
		alpha += (1.0 - T_i) * (1.0 - alpha);
		pos += dir_step;
	}
	
	return clamp(1.0 - alpha, 0.0, 1.0);
}


//-----------------------------------------------------------------------------------------------------------------------------------------------------------------------
float SceneIntersect( Ray r, inout Intersection intersec, bool checkOcean, out float intersectedObjectID )
//-----------------------------------------------------------------------------------------------------------------------------------------------------------------------
{
        Ray rObj;

	vec3 hitObjectSpace;
	vec3 hitWorldSpace;
	vec3 normal;
	vec3 pos;
	vec3 dir;

	float h;
        float d, dw, dc;
	float dx, dy, dz;
	float t = INFINITY;
        float eps = 0.1;
	float waterWaveHeight;

	int objectCount = 0;

	bool isRayExiting = false;
	
	
	
	// SEA FLOOR
	d = PlaneIntersect(vec4(0, 1, 0, -1000.0), r);
	if (d < t)
	{
		t = d;
		intersec.normal = vec3(0,1,0);
		intersec.emission = vec3(0);
		intersec.color = vec3(0.0, 0.07, 0.07);
		intersec.type = SEAFLOOR;
		intersectedObjectID = -1.0;
	}
	
	d = OpenCylinderIntersect( openCylinders[0].pos1, openCylinders[0].pos2, openCylinders[0].radius, r, normal );
	if (d < t)
	{
		t = d;
		intersec.normal = normalize(normal);
		intersec.emission = vec3(0);
		intersec.color = openCylinders[0].color;
		intersec.type = WOOD;
		intersectedObjectID = float(objectCount);
	}
	objectCount++;

	d = OpenCylinderIntersect( openCylinders[1].pos1, openCylinders[1].pos2, openCylinders[1].radius, r, normal );
	if (d < t)
	{
		t = d;
		intersec.normal = normalize(normal);
		intersec.emission = vec3(0);
		intersec.color = openCylinders[0].color;
		intersec.type = WOOD;
		intersectedObjectID = float(objectCount);
	}
	objectCount++;

	d = OpenCylinderIntersect( openCylinders[2].pos1, openCylinders[2].pos2, openCylinders[2].radius, r, normal );
	if (d < t)
	{
		t = d;
		intersec.normal = normalize(normal);
		intersec.emission = vec3(0);
		intersec.color = openCylinders[0].color;
		intersec.type = WOOD;
		intersectedObjectID = float(objectCount);
	}
	objectCount++;

	d = OpenCylinderIntersect( openCylinders[3].pos1, openCylinders[3].pos2, openCylinders[3].radius, r, normal );
	if (d < t)
	{
		t = d;
		intersec.normal = normalize(normal);
		intersec.emission = vec3(0);
		intersec.color = openCylinders[0].color;
		intersec.type = WOOD;
		intersectedObjectID = float(objectCount);
	}
	objectCount++;
	

	for (int i = 0; i < N_QUADS; i++)
        {
		d = QuadIntersect( quads[i].v0, quads[i].v1, quads[i].v2, quads[i].v3, r, true );
		if (d < t)
		{
			t = d;
			intersec.normal = normalize(quads[i].normal);
			intersec.emission = quads[i].emission;
			intersec.color = quads[i].color;
			intersec.type = quads[i].type;
			intersectedObjectID = float(objectCount);
		}
		objectCount++;
        }

	
	// TALL MIRROR BOX
	// transform ray into Tall Box's object space
	rObj.origin = vec3( uTallBoxInvMatrix * vec4(r.origin, 1.0) );
	rObj.direction = vec3( uTallBoxInvMatrix * vec4(r.direction, 0.0) );
	d = BoxIntersect( boxes[0].minCorner, boxes[0].maxCorner, rObj, normal, isRayExiting );
	
	if (d < t)
	{	
		t = d;
		
		// transfom normal back into world space
		normal = normalize(normal);
		intersec.normal = normalize(transpose(mat3(uTallBoxInvMatrix)) * normal);
		intersec.emission = boxes[0].emission;
		intersec.color = boxes[0].color;
		intersec.type = boxes[0].type;
		intersectedObjectID = float(objectCount);
	}
	objectCount++;
	
	
	// SHORT DIFFUSE WHITE BOX
	// transform ray into Short Box's object space
	rObj.origin = vec3( uShortBoxInvMatrix * vec4(r.origin, 1.0) );
	rObj.direction = vec3( uShortBoxInvMatrix * vec4(r.direction, 0.0) );
	d = BoxIntersect( boxes[1].minCorner, boxes[1].maxCorner, rObj, normal, isRayExiting );
	
	if (d < t)
	{	
		t = d;
		
		// transfom normal back into world space
		normal = normalize(normal);
		intersec.normal = normalize(transpose(mat3(uShortBoxInvMatrix)) * normal);
		intersec.emission = boxes[1].emission;
		intersec.color = boxes[1].color;
		intersec.type = boxes[1].type;
		intersectedObjectID = float(objectCount);
	}
	objectCount++;
	
	
	///////////////////////////////////////////////////////////////////////////////////////////////////////
	// OCEAN 
	///////////////////////////////////////////////////////////////////////////////////////////////////////
	
	if ( !checkOcean )
	{
		return t;
	}

	pos = r.origin;
	dir = r.direction;
	h = 0.0;
	d = 0.0; // reset d

	for(int i = 0; i < 100; i++)
	{
		h = abs(pos.y - getOceanWaterHeight(pos));
		if (d > 4000.0 || h < 1.0) break;
		d += h;
		pos += dir * h; 
	}
	hitWorldSpace = pos;
	
	if (d > 4000.0)
	{
		d = PlaneIntersect( vec4(0, 1, 0, 0.0), r );
		if ( d >= INFINITY ) return t;
		hitWorldSpace = r.origin + r.direction * d;
		
		waterWaveHeight = getOceanWaterHeight_Detail(hitWorldSpace);
		d = DisplacementBoxIntersect( vec3(-INFINITY, -INFINITY, -INFINITY), vec3(INFINITY, waterWaveHeight, INFINITY), r);
		hitWorldSpace = r.origin + r.direction * d;
	}
	
	if (d < t) 
	{
		eps = 1.0;
		t = d;
		dx = getOceanWaterHeight_Detail(hitWorldSpace - vec3(eps,0,0)) - getOceanWaterHeight_Detail(hitWorldSpace + vec3(eps,0,0));
		dy = eps * 2.0; // (the water wave height is a function of x and z, not dependent on y)
		dz = getOceanWaterHeight_Detail(hitWorldSpace - vec3(0,0,eps)) - getOceanWaterHeight_Detail(hitWorldSpace + vec3(0,0,eps));
		
		intersec.normal = normalize(vec3(dx,dy,dz));
		intersec.emission = vec3(0);
		intersec.color = vec3(0.6, 1.0, 1.0);
		intersec.type = REFR;
		intersectedObjectID = -1.0; // same as sea floor above
	}
	
	
	return t;
}


//-----------------------------------------------------------------------------------------------------------------------------------------
vec3 CalculateRadiance(Ray r, vec3 sunDirection, out vec3 objectNormal, out vec3 objectColor, out float objectID, out float pixelSharpness)
//-----------------------------------------------------------------------------------------------------------------------------------------
{
	Intersection intersec;

	vec3 randVec = vec3(rng() * 2.0 - 1.0, rng() * 2.0 - 1.0, rng() * 2.0 - 1.0);
	randVec = normalize(randVec);
	Ray cameraRay = r;
	vec3 initialSkyColor = Get_Sky_Color(r, sunDirection);
	
	Ray skyRay = Ray( r.origin * vec3(0.02), normalize(vec3(r.direction.x, abs(r.direction.y), r.direction.z)) );
	float dc = SphereIntersect( 20000.0, vec3(skyRay.origin.x, -19900.0, skyRay.origin.z) + vec3(rng() * 2.0), skyRay );
	vec3 skyPos = skyRay.origin + skyRay.direction * dc;
	vec4 cld = render_clouds(skyRay, skyPos, sunDirection);
	
	Ray cloudShadowRay = Ray(r.origin * vec3(0.02), normalize(sunDirection + (randVec * 0.05)));
	float dcs = SphereIntersect( 20000.0, vec3(skyRay.origin.x, -19900.0, skyRay.origin.z) + vec3(rng() * 2.0), cloudShadowRay );
	vec3 cloudShadowPos = cloudShadowRay.origin + cloudShadowRay.direction * dcs;
	float cloudShadowFactor = checkCloudCover(cloudShadowRay.direction, cloudShadowPos);
	
	vec3 accumCol = vec3(0);
        vec3 mask = vec3(1);
	vec3 n, nl, x;
	vec3 firstX = vec3(0);
	vec3 tdir;
	
	float nc, nt, ratioIoR, Re, Tr;
	float P, RP, TP;
	float weight;
	float t = INFINITY;
	float intersectedObjectID;
	
	int diffuseCount = 0;
	int previousIntersecType = -100;

	bool checkOcean = true;
	bool skyHit = false;
	bool sampleLight = false;
	bool bounceIsSpecular = true;

	
	
        for (int bounces = 0; bounces < 6; bounces++)
	{

		t = SceneIntersect(r, intersec, checkOcean, intersectedObjectID);
		checkOcean = false;

		if (t == INFINITY)
		{
			vec3 skyColor = Get_Sky_Color(r, sunDirection);

			if (bounces == 0) // ray hits sky first
			{
				pixelSharpness = 1.01;
				skyHit = true;
				firstX = skyPos;
				initialSkyColor = mask * skyColor;
				accumCol = initialSkyColor;
				break; // exit early	
			}
			else if (bounces == 1 && previousIntersecType == SPEC) // ray reflects off of mirror box first, then hits sky
			{
				pixelSharpness = 1.01;
				skyHit = true;
				firstX = skyPos;
				initialSkyColor = mask * skyColor;
				accumCol = initialSkyColor;
				break; // exit early	
			}
			else if (diffuseCount == 0 && previousIntersecType == REFR)
			{
				//skyHit = true;
				firstX = skyPos;
				initialSkyColor = mask * skyColor;
				accumCol = initialSkyColor;
				break; // exit early	
			}	
			else if (sampleLight)
			{
				accumCol = mask * skyColor;
				break;
			}
			else if (diffuseCount > 0)
			{
				weight = dot(r.direction, sunDirection) < 0.99 ? 1.0 : 0.0;
				accumCol = mask * skyColor * weight;
				break;
			}
			
			// reached the sky light, so we can exit
			break;
		} // end if (t == INFINITY)

		
		if (intersec.type == SEAFLOOR)
		{
			pixelSharpness = -1.0;

			checkOcean = false;

			float waterDotSun = max(0.0, dot(vec3(0,1,0), sunDirection));
			float waterDotCamera = max(0.4, dot(vec3(0,1,0), -cameraRay.direction));

			accumCol = mask * intersec.color * waterDotSun * waterDotCamera;
			break;
		} // end if (intersec.type == SEAFLOOR)


		//if we get here and sampleLight is still true, shadow ray failed to find a light source
		if (sampleLight) 	
			break;
		
		
		
		// useful data 
		n = normalize(intersec.normal);
                nl = dot(n, r.direction) < 0.0 ? normalize(n) : normalize(-n);
		x = r.origin + r.direction * t;
			
		if (bounces == 0)
		{
			firstX = x;

			objectNormal = nl;
			objectColor = intersec.color;
			objectID = intersectedObjectID;
		}
		if (bounces == 1 && previousIntersecType == SPEC)
		{
			objectNormal = nl;
		}

		
                if (intersec.type == DIFF) // Ideal DIFFUSE reflection
                {	
			previousIntersecType = DIFF;

			checkOcean = false;

			diffuseCount++;

			mask *= intersec.color;

			bounceIsSpecular = false;

			if (diffuseCount == 1 && rand() < 0.5)
			{
				// choose random Diffuse sample vector
				r = Ray( x, normalize(randomCosWeightedDirectionInHemisphere(nl)) );
				r.origin += nl * uEPS_intersect;
				continue;
			}
                        
			r = Ray( x, normalize(sunDirection) );// create shadow ray pointed towards light
			r.direction = randomDirectionInSpecularLobe(r.direction, 0.1);
			r.origin += nl * uEPS_intersect;
			
			weight = max(0.0, dot(r.direction, nl)) * 0.05; // down-weight directSunLight contribution
			mask *= weight * cloudShadowFactor;
			
			sampleLight = true;
			continue;
                        
                } // end if (intersec.type == DIFF)
		
                if (intersec.type == SPEC)  // Ideal SPECULAR reflection
                {
			previousIntersecType = SPEC;

			mask *= intersec.color;

			r = Ray( x, reflect(r.direction, nl) );
			r.origin += nl * uEPS_intersect;

			if (bounces == 0)
				checkOcean = true;

			//bounceIsSpecular = true; // turn on mirror caustics
			continue;
                }
		
		if (intersec.type == REFR)  // Ideal dielectric REFRACTION
		{
			//previousIntersecType = REFR;
			// must be placed under the if statement below that uses previousIntersecType

			if (diffuseCount == 0)
				pixelSharpness = -1.0;

			checkOcean = false;
			
			nc = 1.0; // IOR of Air
			nt = 1.33; // IOR of Water
			Re = calcFresnelReflectance(r.direction, n, nc, nt, ratioIoR);
			Tr = 1.0 - Re;
			P  = 0.25 + (0.5 * Re);
                	RP = Re / P;
                	TP = Tr / (1.0 - P);
			
			if (rand() < P && (bounces == 0 || (bounces == 1 && previousIntersecType == SPEC)) )
			{	
				previousIntersecType = REFR;
				mask *= RP;
				r = Ray( x, reflect(r.direction, nl) ); // create reflection ray from surface
				r.origin += nl * uEPS_intersect;
				continue;
			}
			
			previousIntersecType = REFR;

			mask *= TP;
			mask *= intersec.color;

			// transmit ray through surface
			tdir = refract(r.direction, nl, ratioIoR);
			r = Ray(x, normalize(tdir));
			r.origin -= nl * uEPS_intersect;	

			continue;
			
		} // end if (intersec.type == REFR)
		
		if (intersec.type == WOOD)  // Diffuse object underneath with thin layer of Water on top
		{
			previousIntersecType = COAT;

			checkOcean = false;
			
			nc = 1.0; // IOR of air
			nt = 1.1; // IOR of ClearCoat 
			Re = calcFresnelReflectance(r.direction, n, nc, nt, ratioIoR);
			Tr = 1.0 - Re;
			P  = 0.25 + (0.5 * Re);
                	RP = Re / P;
                	TP = Tr / (1.0 - P);
			
			if (rand() < P)
			{
				mask *= RP;
				r = Ray( x, reflect(r.direction, nl) ); // reflect ray from surface
				r.origin += nl * uEPS_intersect;
				continue;
			}

			mask *= TP;
			
			float pattern = noise( vec2( x.x * 0.5 * x.z * 0.5 + sin(x.y*0.005) ) );
			float woodPattern = 1.0 / max(1.0, pattern * 100.0);
			intersec.color *= woodPattern;

			if (bounces == 0)
				objectColor = intersec.color;
			
			mask *= intersec.color;

			diffuseCount++;

			bounceIsSpecular = false;

			if (diffuseCount == 1 && rand() < 0.5)
			{
				// choose random Diffuse sample vector
				r = Ray( x, randomCosWeightedDirectionInHemisphere(nl) );
				r.origin += nl * uEPS_intersect;
				continue;
			}
			
			r = Ray( x, sunDirection);// create shadow ray pointed towards light
			r.direction = randomDirectionInSpecularLobe(r.direction, 0.1);
			r.origin += nl * uEPS_intersect;

			weight = max(0.0, dot(r.direction, nl)) * 0.05; // down-weight directSunLight contribution
			mask *= weight;
			
			sampleLight = true;
			continue;
			
		} //end if (intersec.type == WOOD)
		
	} // end for (int bounces = 0; bounces < 6; bounces++)
	

	// atmospheric haze effect (aerial perspective)
	float hitDistance;
	
	if ( skyHit ) // sky and clouds
	{
		vec3 cloudColor = cld.rgb / (cld.a + 0.00001);
		vec3 sunColor = clamp(Get_Sky_Color( Ray(skyPos, randomDirectionInSpecularLobe(sunDirection, 0.1)), sunDirection ), 0.0, 5.0);
		
		cloudColor *= sunColor;
		cloudColor = mix(initialSkyColor, cloudColor, clamp(cld.a, 0.0, 1.0));
		
		hitDistance = distance(skyRay.origin, skyPos);
		accumCol = mask * mix( accumCol, cloudColor, clamp( exp2( -hitDistance * 0.004 ), 0.0, 1.0 ) );
	}
	else // terrain and other objects
	{
		hitDistance = distance(cameraRay.origin, firstX);
		accumCol = mix( initialSkyColor, accumCol, clamp( exp2( -log(hitDistance * 0.00003) ), 0.0, 1.0 ) );

		// underwater fog effect
		hitDistance = distance(cameraRay.origin, firstX);
		hitDistance *= uCameraUnderWater;
		accumCol = mix( vec3(0.0,0.05,0.05), accumCol, clamp( exp2( -hitDistance * 0.001 ), 0.0, 1.0 ) );
	}


	return max(vec3(0), accumCol); // prevents black spot artifacts appearing in the water

}


//-----------------------------------------------------------------------
void SetupScene( void )
//-----------------------------------------------------------------------
{
	vec3 z  = vec3(0);// No color value, Black
	
	quads[0] = Quad( vec3(0,0,1), vec3(  0.0, 0.0,-559.2), vec3(549.6, 0.0,-559.2), vec3(549.6, 548.8,-559.2), vec3(  0.0, 548.8,-559.2),    z, vec3(0.9),  DIFF);// Back Wall
	quads[1] = Quad( vec3(1,0,0),vec3(  0.0, 0.0,   0.0), vec3(  0.0, 0.0,-559.2), vec3(  0.0, 548.8,-559.2), vec3(  0.0, 548.8,   0.0),    z, vec3(0.7, 0.12,0.05),  DIFF);// Left Wall Red
	quads[2] = Quad( vec3(-1,0,0),vec3(549.6, 0.0,-559.2), vec3(549.6, 0.0,   0.0), vec3(549.6, 548.8,   0.0), vec3(549.6, 548.8,-559.2),    z, vec3(0.2, 0.4, 0.36),  DIFF);// Right Wall Green
	//quads[3] = Quad( vec3(0,-1,0), vec3(  0.0, 548.8,-559.2), vec3(549.6, 548.8,-559.2), vec3(549.6, 548.8,   0.0), vec3(0.0, 548.8, 0.0),  z, vec3(0.9),  DIFF);// Ceiling
	quads[3] = Quad( vec3(0,1,0),vec3(  0.0, 0.0,   0.0), vec3(549.6, 0.0,   0.0), vec3(549.6, 0.0,-559.2), vec3(  0.0, 0.0,-559.2),    z, vec3(0.9), DIFF);// Floor
	
	openCylinders[0] = OpenCylinder( 50.0, vec3(50 , 0, -50), vec3(50 ,-1000, -50), z, vec3(0.05, 0.0, 0.0), WOOD);// wooden support OpenCylinder
	openCylinders[1] = OpenCylinder( 50.0, vec3(500, 0, -50), vec3(500,-1000, -50), z, vec3(0.05, 0.0, 0.0), WOOD);// wooden support OpenCylinder
	openCylinders[2] = OpenCylinder( 50.0, vec3(50 , 0,-510), vec3(50 ,-1000,-510), z, vec3(0.05, 0.0, 0.0), WOOD);// wooden support OpenCylinder
	openCylinders[3] = OpenCylinder( 50.0, vec3(500, 0,-510), vec3(500,-1000,-510), z, vec3(0.05, 0.0, 0.0), WOOD);// wooden support OpenCylinder
	
	boxes[0] = Box( vec3( -82.0,-170.0, -80.0), vec3(  82.0, 170.0,   80.0), z, vec3(1.0), SPEC);// Tall Mirror Box Left
	boxes[1] = Box( vec3( -86.0, -85.0, -80.0), vec3(  86.0,  85.0,   80.0), z, vec3(0.9), DIFF);// Short Diffuse Box Right
}


// tentFilter from Peter Shirley's 'Realistic Ray Tracing (2nd Edition)' book, pg. 60		
float tentFilter(float x)
{
	return (x < 0.5) ? sqrt(2.0 * x) - 1.0 : 1.0 - sqrt(2.0 - (2.0 * x));
}


void main( void )
{
        vec3 camRight   = vec3( uCameraMatrix[0][0],  uCameraMatrix[0][1],  uCameraMatrix[0][2]);
        vec3 camUp      = vec3( uCameraMatrix[1][0],  uCameraMatrix[1][1],  uCameraMatrix[1][2]);
        vec3 camForward = vec3(-uCameraMatrix[2][0], -uCameraMatrix[2][1], -uCameraMatrix[2][2]);
	// the following is not needed - three.js has a built-in uniform named cameraPosition
	//vec3 camPos   = vec3( uCameraMatrix[3][0],  uCameraMatrix[3][1],  uCameraMatrix[3][2]);
        
        // calculate unique seed for rng() function
	seed = uvec2(uFrameCounter, uFrameCounter + 1.0) * uvec2(gl_FragCoord);

	// initialize rand() variables
	counter = -1.0; // will get incremented by 1 on each call to rand()
	channel = 0; // the final selected color channel to use for rand() calc (range: 0 to 3, corresponds to R,G,B, or A)
	randNumber = 0.0; // the final randomly-generated number (range: 0.0 to 1.0)
	randVec4 = vec4(0); // samples and holds the RGBA blueNoise texture value for this pixel
	randVec4 = texelFetch(tBlueNoiseTexture, ivec2(mod(gl_FragCoord.xy + floor(uRandomVec2 * 256.0), 256.0)), 0);
	
	vec2 pixelOffset = vec2( tentFilter(rng()), tentFilter(rng()) ) * 0.5;
	//vec2 pixelOffset = vec2(0);

	// we must map pixelPos into the range -1.0 to +1.0
	vec2 pixelPos = ((gl_FragCoord.xy + pixelOffset) / uResolution) * 2.0 - 1.0;

	vec3 rayDir = normalize( pixelPos.x * camRight * uULen + pixelPos.y * camUp * uVLen + camForward );
	
	// depth of field
	vec3 focalPoint = uFocusDistance * rayDir;
	float randomAngle = rand() * TWO_PI; // pick random point on aperture
	float randomRadius = rand() * uApertureSize;
	vec3  randomAperturePos = ( cos(randomAngle) * camRight + sin(randomAngle) * camUp ) * sqrt(randomRadius);
	// point on aperture to focal point
	vec3 finalRayDir = normalize(focalPoint - randomAperturePos);
	
	Ray ray = Ray( cameraPosition + randomAperturePos, finalRayDir );

        SetupScene(); 

        // Edge Detection - don't want to blur edges where either surface normals change abruptly (i.e. room wall corners), objects overlap each other (i.e. edge of a foreground sphere in front of another sphere right behind it),
	// or an abrupt color variation on the same smooth surface, even if it has similar surface normals (i.e. checkerboard pattern). Want to keep all of these cases as sharp as possible - no blur filter will be applied.
	vec3 objectNormal, objectColor;
	float objectID = -INFINITY;
	float pixelSharpness = 0.0;
	
	// perform path tracing and get resulting pixel color
	vec4 currentPixel = vec4( vec3(CalculateRadiance(ray, uSunDirection, objectNormal, objectColor, objectID, pixelSharpness)), 0.0 );

	// if difference between normals of neighboring pixels is less than the first edge0 threshold, the white edge line effect is considered off (0.0)
	float edge0 = 0.2; // edge0 is the minimum difference required between normals of neighboring pixels to start becoming a white edge line
	// any difference between normals of neighboring pixels that is between edge0 and edge1 smoothly ramps up the white edge line brightness (smoothstep 0.0-1.0)
	float edge1 = 0.6; // once the difference between normals of neighboring pixels is >= this edge1 threshold, the white edge line is considered fully bright (1.0)
	float difference_Nx = fwidth(objectNormal.x);
	float difference_Ny = fwidth(objectNormal.y);
	float difference_Nz = fwidth(objectNormal.z);
	float normalDifference = smoothstep(edge0, edge1, difference_Nx) + smoothstep(edge0, edge1, difference_Ny) + smoothstep(edge0, edge1, difference_Nz);

	edge0 = 0.0;
	edge1 = 0.5;
	float difference_obj = abs(dFdx(objectID)) > 0.0 ? 1.0 : 0.0;
	difference_obj += abs(dFdy(objectID)) > 0.0 ? 1.0 : 0.0;
	float objectDifference = smoothstep(edge0, edge1, difference_obj);

	float difference_col = length(dFdx(objectColor)) > 0.0 ? 1.0 : 0.0;
	difference_col += length(dFdy(objectColor)) > 0.0 ? 1.0 : 0.0;
	float colorDifference = smoothstep(edge0, edge1, difference_col);
	// edge detector (normal and object differences) white-line debug visualization
	//currentPixel.rgb += 1.0 * vec3(max(normalDifference, objectDifference));
	
	vec4 previousPixel = texelFetch(tPreviousTexture, ivec2(gl_FragCoord.xy), 0);

	
	if (uCameraIsMoving) // camera is currently moving
	{
		previousPixel.rgb *= 0.7; // motion-blur trail amount (old image)
		currentPixel.rgb *= 0.3; // brightness of new image (noisy)

		previousPixel.a = 0.0;
	}
	else
	{
		previousPixel.rgb *= 0.9; // motion-blur trail amount (old image)
		currentPixel.rgb *= 0.1; // brightness of new image (noisy)
	}

	currentPixel.a = 0.0;
	if (colorDifference >= 1.0 || normalDifference >= 1.0 || objectDifference >= 1.0)
		pixelSharpness = 1.01;

	
	// Eventually, all edge-containing pixels' .a (alpha channel) values will converge to 1.01, which keeps them from getting blurred by the box-blur filter, thus retaining sharpness.
	if (previousPixel.a == 1.01)
		currentPixel.a = 1.01;
	// for dynamic scenes
	if (previousPixel.a == 1.01 && rng() < 0.05)
		currentPixel.a = 1.0;
	if (previousPixel.a == -1.0)
		currentPixel.a = 0.0;

	if (pixelSharpness == 1.01)
		currentPixel.a = 1.01;
	if (pixelSharpness == -1.0)
		currentPixel.a = -1.0;

	
	pc_fragColor = vec4(previousPixel.rgb + currentPixel.rgb, currentPixel.a);
}
