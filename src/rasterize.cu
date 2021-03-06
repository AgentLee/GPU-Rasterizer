/**
 * @file      rasterize.cu
 * @brief     CUDA-accelerated rasterization pipeline.
 * @authors   Skeleton code: Yining Karl Li, Kai Ninomiya, Shuai Shao (Shrek)
 * @date      2012-2016
 * @copyright University of Pennsylvania & STUDENT
 */

#include <cmath>
#include <cstdio>
#include <cuda.h>
#include <cuda_runtime.h>
#include <thrust/random.h>
#include <util/checkCUDAError.h>
#include <util/tiny_gltf_loader.h>
#include "rasterizeTools.h"
#include "rasterize.h"
#include <glm/gtc/quaternion.hpp>
#include <glm/gtc/matrix_transform.hpp>
#include <thrust/execution_policy.h>
#include <thrust/random.h>
#include <thrust/remove.h>
#include <thrust/partition.h>
#include "../stream_compaction/common.h"

#define BACKFACE_CULLING 0
#define DRAWLINES 0
#define DRAWPOINTS 0
#define TEXTURE 1
#define BILINEAR 1
#define PERPSECTIVE_CORRECT 1
#define MUTEX 1

namespace {

	typedef unsigned short VertexIndex;
	typedef glm::vec3 VertexAttributePosition;
	typedef glm::vec3 VertexAttributeNormal;
	typedef glm::vec2 VertexAttributeTexcoord;
	typedef unsigned char TextureData;

	typedef unsigned char BufferByte;

	enum PrimitiveType {
		Point		= 1,
		Line		= 2,
		Triangle	= 3
	};

	// Assembled and transformed vertices
	struct VertexOut {
		glm::vec4 pos;

		// TODO: add new attributes to your VertexOut
		// The attributes listed below might be useful, 
		// but always feel free to modify on your own

		 glm::vec3 eyePos;	// eye space position used for shading
		 glm::vec3 eyeNor;	// eye space normal used for shading, cuz normal will go wrong after perspective transformation
		 glm::vec3 col;
		 glm::vec2 texcoord0;
		 TextureData* dev_diffuseTex = NULL;
		 int texWidth, texHeight;
		// ...
	};

	struct Primitive {
		PrimitiveType primitiveType = Triangle;	// C++ 11 init
		VertexOut v[3];
	};

	struct Fragment {
		glm::vec3 color;

		// TODO: add new attributes to your Fragment
		// The attributes listed below might be useful, 
		// but always feel free to modify on your own

		 glm::vec3 eyePos;	// eye space position used for shading
		 glm::vec3 eyeNor;
		 VertexAttributeTexcoord texcoord0;
		 TextureData* dev_diffuseTex;
		 int diffuseTexWidth;
		 int diffuseTexHeight;
		// ...
	};

	// Buffers from glTF
	// Passed into _vertexTransformAndAssembly 
	struct PrimitiveDevBufPointers {
		int primitiveMode;	//from tinygltfloader macro
		PrimitiveType primitiveType;
		int numPrimitives;
		int numIndices;
		int numVertices;

		// Vertex In, const after loaded
		VertexIndex* dev_indices;
		VertexAttributePosition* dev_position;
		VertexAttributeNormal* dev_normal;
		VertexAttributeTexcoord* dev_texcoord0;

		// Materials, add more attributes when needed
		TextureData* dev_diffuseTex;
		int diffuseTexWidth;
		int diffuseTexHeight;
		// TextureData* dev_specularTex;
		// TextureData* dev_normalTex;
		// ...

		// Vertex Out, vertex used for rasterization, this is changing every frame
		VertexOut* dev_verticesOut;

		// TODO: add more attributes when needed
	};

}

static std::map<std::string, std::vector<PrimitiveDevBufPointers>> mesh2PrimitivesMap;


static int width = 0;
static int height = 0;

static int totalNumPrimitives = 0;
static Primitive *dev_primitives = NULL;
static Fragment *dev_fragmentBuffer = NULL;
static glm::vec3 *dev_framebuffer = NULL;

static int * dev_depth = NULL;	// you might need this buffer when doing depth test
static int * dev_mutex = NULL;

/**
 * Kernel that writes the image to the OpenGL PBO directly.
 */
__global__ 
void sendImageToPBO(uchar4 *pbo, int w, int h, glm::vec3 *image) {
    int x = (blockIdx.x * blockDim.x) + threadIdx.x;
    int y = (blockIdx.y * blockDim.y) + threadIdx.y;
    int index = x + (y * w);

    if (x < w && y < h) {
        glm::vec3 color;
        color.x = glm::clamp(image[index].x, 0.0f, 1.0f) * 255.0;
        color.y = glm::clamp(image[index].y, 0.0f, 1.0f) * 255.0;
        color.z = glm::clamp(image[index].z, 0.0f, 1.0f) * 255.0;
        // Each thread writes one pixel location in the texture (textel)
        pbo[index].w = 0;
        pbo[index].x = color.x;
        pbo[index].y = color.y;
        pbo[index].z = color.z;
    }
}

/** 
* Writes fragment colors to the framebuffer
*/
__global__
void render(int w, int h, Fragment *fragmentBuffer, glm::vec3 *framebuffer) {
    int x = (blockIdx.x * blockDim.x) + threadIdx.x;
    int y = (blockIdx.y * blockDim.y) + threadIdx.y;
    int index = x + (y * w);

    if (x < w && y < h) {
		glm::vec3 lightPos(10.f, 20.f, 30.f);
		glm::vec3 intensity(1.5f);

		if (DRAWPOINTS || DRAWLINES) {
			framebuffer[index] = fragmentBuffer[index].color;
			return;
		}

		// Use Lambert
		if (fragmentBuffer[index].dev_diffuseTex == NULL || !TEXTURE) {
			glm::vec3 lightWi = glm::normalize(fragmentBuffer[index].eyePos - lightPos);

			float absDot = glm::abs(glm::dot(fragmentBuffer[index].eyeNor, lightWi));
			glm::vec3 col = fragmentBuffer[index].color * intensity * absDot;

			framebuffer[index] = glm::clamp(col, 0.f, 1.f);
		}
		// Use texture
		else if(TEXTURE) {
			glm::vec3 color(0.f);

			if (BILINEAR) {
				// Bilinear
				TextureData* tex = fragmentBuffer[index].dev_diffuseTex;
				int width = fragmentBuffer[index].diffuseTexWidth;
				int height = fragmentBuffer[index].diffuseTexHeight;

				float u = fragmentBuffer[index].texcoord0.x * width;
				float v = fragmentBuffer[index].texcoord0.y * height;

				int x = glm::floor(u);
				int y = glm::floor(v);

				float uRatio = u - x;
				float vRatio = v - y;

				float uOpposite = 1.f - uRatio;
				float vOpposite = 1.f - vRatio;

				int uvIndex1 = 3 * (x + y * width);
				int uvIndex2 = 3 * (x + 1 + y * width);
				int uvIndex3 = 3 * (x + (y + 1) * width);
				int uvIndex4 = 3 * (x + 1 + (y + 1) * width);

				// https://en.wikipedia.org/wiki/Bilinear_filtering
				float r = (tex[uvIndex1] * uOpposite + tex[uvIndex2] * uRatio) * vOpposite +
					(tex[uvIndex3] * uOpposite + tex[uvIndex4] * uRatio) * vRatio;
				float g = (tex[uvIndex1 + 1] * uOpposite + tex[uvIndex2 + 1] * uRatio) * vOpposite +
					(tex[uvIndex3 + 1] * uOpposite + tex[uvIndex4 + 1] * uRatio) * vRatio;
				float b = (tex[uvIndex1 + 2] * uOpposite + tex[uvIndex2 + 2] * uRatio) * vOpposite +
					(tex[uvIndex3 + 2] * uOpposite + tex[uvIndex4 + 2] * uRatio) * vRatio;

				color = glm::vec3(r, g, b);
				color /= 255.f;

				framebuffer[index] = color;
			}
			else {
				// Not bilinear
				int u = fragmentBuffer[index].texcoord0.x * fragmentBuffer[index].diffuseTexWidth;
				int v = fragmentBuffer[index].texcoord0.y * fragmentBuffer[index].diffuseTexHeight;

				// https://stackoverflow.com/questions/35005603/get-color-of-the-texture-at-uv-coordinate
				int uvIndex = 3 * (u + (v * fragmentBuffer[index].diffuseTexWidth));

				// https://www.opengl.org/discussion_boards/showthread.php/170651-Is-it-possible-to-get-the-pixel-color
				float r = fragmentBuffer[index].dev_diffuseTex[uvIndex];
				float g = fragmentBuffer[index].dev_diffuseTex[uvIndex + 1];
				float b = fragmentBuffer[index].dev_diffuseTex[uvIndex + 2];

				color = glm::vec3(r, g, b);
				color /= 255.f;

				framebuffer[index] = color;
			}
		}
		// TODO: add your fragment shader code here
    }
}

/**
 * Called once at the beginning of the program to allocate memory.
 */
void rasterizeInit(int w, int h) {
    width = w;
    height = h;
	cudaFree(dev_fragmentBuffer);
	cudaMalloc(&dev_fragmentBuffer, width * height * sizeof(Fragment));
	cudaMemset(dev_fragmentBuffer, 0, width * height * sizeof(Fragment));
    cudaFree(dev_framebuffer);
    cudaMalloc(&dev_framebuffer,   width * height * sizeof(glm::vec3));
    cudaMemset(dev_framebuffer, 0, width * height * sizeof(glm::vec3));
    
	cudaFree(dev_depth);
	cudaMalloc(&dev_depth, width * height * sizeof(int));

	cudaFree(dev_mutex);
	cudaMalloc(&dev_mutex, width * height * sizeof(int));
	cudaMemset(&dev_mutex, 0, width * height * sizeof(int));

	checkCUDAError("rasterizeInit");
}

__global__
void initDepth(int w, int h, int * depth)
{
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;

	if (x < w && y < h)
	{
		int index = x + (y * w);
		depth[index] = INT_MAX;
	}
}


/**
* kern function with support for stride to sometimes replace cudaMemcpy
* One thread is responsible for copying one component
*/
__global__ 
void _deviceBufferCopy(int N, BufferByte* dev_dst, const BufferByte* dev_src, int n, int byteStride, int byteOffset, int componentTypeByteSize) {
	
	// Attribute (vec3 position)
	// component (3 * float)
	// byte (4 * byte)

	// id of component
	int i = (blockIdx.x * blockDim.x) + threadIdx.x;

	if (i < N) {
		int count = i / n;
		int offset = i - count * n;	// which component of the attribute

		for (int j = 0; j < componentTypeByteSize; j++) {
			
			dev_dst[count * componentTypeByteSize * n 
				+ offset * componentTypeByteSize 
				+ j]

				= 

			dev_src[byteOffset 
				+ count * (byteStride == 0 ? componentTypeByteSize * n : byteStride) 
				+ offset * componentTypeByteSize 
				+ j];
		}
	}
	

}

__global__
void _nodeMatrixTransform(
	int numVertices,
	VertexAttributePosition* position,
	VertexAttributeNormal* normal,
	glm::mat4 MV, glm::mat3 MV_normal) {

	// vertex id
	int vid = (blockIdx.x * blockDim.x) + threadIdx.x;
	if (vid < numVertices) {
		position[vid] = glm::vec3(MV * glm::vec4(position[vid], 1.0f));
		normal[vid] = glm::normalize(MV_normal * normal[vid]);
	}
}

glm::mat4 getMatrixFromNodeMatrixVector(const tinygltf::Node & n) {
	
	glm::mat4 curMatrix(1.0);

	const std::vector<double> &m = n.matrix;
	if (m.size() > 0) {
		// matrix, copy it

		for (int i = 0; i < 4; i++) {
			for (int j = 0; j < 4; j++) {
				curMatrix[i][j] = (float)m.at(4 * i + j);
			}
		}
	} else {
		// no matrix, use rotation, scale, translation

		if (n.translation.size() > 0) {
			curMatrix[3][0] = n.translation[0];
			curMatrix[3][1] = n.translation[1];
			curMatrix[3][2] = n.translation[2];
		}

		if (n.rotation.size() > 0) {
			glm::mat4 R;
			glm::quat q;
			q[0] = n.rotation[0];
			q[1] = n.rotation[1];
			q[2] = n.rotation[2];

			R = glm::mat4_cast(q);
			curMatrix = curMatrix * R;
		}

		if (n.scale.size() > 0) {
			curMatrix = curMatrix * glm::scale(glm::vec3(n.scale[0], n.scale[1], n.scale[2]));
		}
	}

	return curMatrix;
}

void traverseNode (
	std::map<std::string, glm::mat4> & n2m,
	const tinygltf::Scene & scene,
	const std::string & nodeString,
	const glm::mat4 & parentMatrix
	) 
{
	const tinygltf::Node & n = scene.nodes.at(nodeString);
	glm::mat4 M = parentMatrix * getMatrixFromNodeMatrixVector(n);
	n2m.insert(std::pair<std::string, glm::mat4>(nodeString, M));

	auto it = n.children.begin();
	auto itEnd = n.children.end();

	for (; it != itEnd; ++it) {
		traverseNode(n2m, scene, *it, M);
	}
}

void rasterizeSetBuffers(const tinygltf::Scene & scene) {

	totalNumPrimitives = 0;

	std::map<std::string, BufferByte*> bufferViewDevPointers;

	// 1. copy all `bufferViews` to device memory
	{
		std::map<std::string, tinygltf::BufferView>::const_iterator it(
			scene.bufferViews.begin());
		std::map<std::string, tinygltf::BufferView>::const_iterator itEnd(
			scene.bufferViews.end());

		for (; it != itEnd; it++) {
			const std::string key = it->first;
			const tinygltf::BufferView &bufferView = it->second;
			if (bufferView.target == 0) {
				continue; // Unsupported bufferView.
			}

			const tinygltf::Buffer &buffer = scene.buffers.at(bufferView.buffer);

			BufferByte* dev_bufferView;
			cudaMalloc(&dev_bufferView, bufferView.byteLength);
			cudaMemcpy(dev_bufferView, &buffer.data.front() + bufferView.byteOffset, bufferView.byteLength, cudaMemcpyHostToDevice);

			checkCUDAError("Set BufferView Device Mem");

			bufferViewDevPointers.insert(std::make_pair(key, dev_bufferView));

		}
	}



	// 2. for each mesh: 
	//		for each primitive: 
	//			build device buffer of indices, materail, and each attributes
	//			and store these pointers in a map
	{

		std::map<std::string, glm::mat4> nodeString2Matrix;
		auto rootNodeNamesList = scene.scenes.at(scene.defaultScene);

		{
			auto it = rootNodeNamesList.begin();
			auto itEnd = rootNodeNamesList.end();
			for (; it != itEnd; ++it) {
				traverseNode(nodeString2Matrix, scene, *it, glm::mat4(1.0f));
			}
		}


		// parse through node to access mesh

		auto itNode = nodeString2Matrix.begin();
		auto itEndNode = nodeString2Matrix.end();
		for (; itNode != itEndNode; ++itNode) {

			const tinygltf::Node & N = scene.nodes.at(itNode->first);
			const glm::mat4 & matrix = itNode->second;
			const glm::mat3 & matrixNormal = glm::transpose(glm::inverse(glm::mat3(matrix)));

			auto itMeshName = N.meshes.begin();
			auto itEndMeshName = N.meshes.end();

			for (; itMeshName != itEndMeshName; ++itMeshName) {

				const tinygltf::Mesh & mesh = scene.meshes.at(*itMeshName);

				auto res = mesh2PrimitivesMap.insert(std::pair<std::string, std::vector<PrimitiveDevBufPointers>>(mesh.name, std::vector<PrimitiveDevBufPointers>()));
				std::vector<PrimitiveDevBufPointers> & primitiveVector = (res.first)->second;

				// for each primitive
				for (size_t i = 0; i < mesh.primitives.size(); i++) {
					const tinygltf::Primitive &primitive = mesh.primitives[i];

					if (primitive.indices.empty())
						return;

					// TODO: add new attributes for your PrimitiveDevBufPointers when you add new attributes
					VertexIndex* dev_indices = NULL;
					VertexAttributePosition* dev_position = NULL;
					VertexAttributeNormal* dev_normal = NULL;
					VertexAttributeTexcoord* dev_texcoord0 = NULL;

					// ----------Indices-------------

					const tinygltf::Accessor &indexAccessor = scene.accessors.at(primitive.indices);
					const tinygltf::BufferView &bufferView = scene.bufferViews.at(indexAccessor.bufferView);
					BufferByte* dev_bufferView = bufferViewDevPointers.at(indexAccessor.bufferView);

					// assume type is SCALAR for indices
					int n = 1;
					int numIndices = indexAccessor.count;
					int componentTypeByteSize = sizeof(VertexIndex);
					int byteLength = numIndices * n * componentTypeByteSize;

					dim3 numThreadsPerBlock(128);
					dim3 numBlocks((numIndices + numThreadsPerBlock.x - 1) / numThreadsPerBlock.x);
					cudaMalloc(&dev_indices, byteLength);
					_deviceBufferCopy << <numBlocks, numThreadsPerBlock >> > (
						numIndices,
						(BufferByte*)dev_indices,
						dev_bufferView,
						n,
						indexAccessor.byteStride,
						indexAccessor.byteOffset,
						componentTypeByteSize);


					checkCUDAError("Set Index Buffer");


					// ---------Primitive Info-------

					// Warning: LINE_STRIP is not supported in tinygltfloader
					int numPrimitives;
					PrimitiveType primitiveType;
					switch (primitive.mode) {
					case TINYGLTF_MODE_TRIANGLES:
						primitiveType = PrimitiveType::Triangle;
						numPrimitives = numIndices / 3;
						break;
					case TINYGLTF_MODE_TRIANGLE_STRIP:
						primitiveType = PrimitiveType::Triangle;
						numPrimitives = numIndices - 2;
						break;
					case TINYGLTF_MODE_TRIANGLE_FAN:
						primitiveType = PrimitiveType::Triangle;
						numPrimitives = numIndices - 2;
						break;
					case TINYGLTF_MODE_LINE:
						primitiveType = PrimitiveType::Line;
						numPrimitives = numIndices / 2;
						break;
					case TINYGLTF_MODE_LINE_LOOP:
						primitiveType = PrimitiveType::Line;
						numPrimitives = numIndices + 1;
						break;
					case TINYGLTF_MODE_POINTS:
						primitiveType = PrimitiveType::Point;
						numPrimitives = numIndices;
						break;
					default:
						// output error
						break;
					};


					// ----------Attributes-------------

					auto it(primitive.attributes.begin());
					auto itEnd(primitive.attributes.end());

					int numVertices = 0;
					// for each attribute
					for (; it != itEnd; it++) {
						const tinygltf::Accessor &accessor = scene.accessors.at(it->second);
						const tinygltf::BufferView &bufferView = scene.bufferViews.at(accessor.bufferView);

						int n = 1;
						if (accessor.type == TINYGLTF_TYPE_SCALAR) {
							n = 1;
						}
						else if (accessor.type == TINYGLTF_TYPE_VEC2) {
							n = 2;
						}
						else if (accessor.type == TINYGLTF_TYPE_VEC3) {
							n = 3;
						}
						else if (accessor.type == TINYGLTF_TYPE_VEC4) {
							n = 4;
						}

						BufferByte * dev_bufferView = bufferViewDevPointers.at(accessor.bufferView);
						BufferByte ** dev_attribute = NULL;

						numVertices = accessor.count;
						int componentTypeByteSize;

						// Note: since the type of our attribute array (dev_position) is static (float32)
						// We assume the glTF model attribute type are 5126(FLOAT) here

						if (it->first.compare("POSITION") == 0) {
							componentTypeByteSize = sizeof(VertexAttributePosition) / n;
							dev_attribute = (BufferByte**)&dev_position;
						}
						else if (it->first.compare("NORMAL") == 0) {
							componentTypeByteSize = sizeof(VertexAttributeNormal) / n;
							dev_attribute = (BufferByte**)&dev_normal;
						}
						else if (it->first.compare("TEXCOORD_0") == 0) {
							componentTypeByteSize = sizeof(VertexAttributeTexcoord) / n;
							dev_attribute = (BufferByte**)&dev_texcoord0;
						}

						std::cout << accessor.bufferView << "  -  " << it->second << "  -  " << it->first << '\n';

						dim3 numThreadsPerBlock(128);
						dim3 numBlocks((n * numVertices + numThreadsPerBlock.x - 1) / numThreadsPerBlock.x);
						int byteLength = numVertices * n * componentTypeByteSize;
						cudaMalloc(dev_attribute, byteLength);

						_deviceBufferCopy << <numBlocks, numThreadsPerBlock >> > (
							n * numVertices,
							*dev_attribute,
							dev_bufferView,
							n,
							accessor.byteStride,
							accessor.byteOffset,
							componentTypeByteSize);

						std::string msg = "Set Attribute Buffer: " + it->first;
						checkCUDAError(msg.c_str());
					}

					// malloc for VertexOut
					VertexOut* dev_vertexOut;
					cudaMalloc(&dev_vertexOut, numVertices * sizeof(VertexOut));
					checkCUDAError("Malloc VertexOut Buffer");

					// ----------Materials-------------

					// You can only worry about this part once you started to 
					// implement textures for your rasterizer
					TextureData* dev_diffuseTex = NULL;
					int diffuseTexWidth = 0;
					int diffuseTexHeight = 0;
					if (!primitive.material.empty()) {
						const tinygltf::Material &mat = scene.materials.at(primitive.material);
						printf("material.name = %s\n", mat.name.c_str());

						if (mat.values.find("diffuse") != mat.values.end()) {
							std::string diffuseTexName = mat.values.at("diffuse").string_value;
							if (scene.textures.find(diffuseTexName) != scene.textures.end()) {
								const tinygltf::Texture &tex = scene.textures.at(diffuseTexName);
								if (scene.images.find(tex.source) != scene.images.end()) {
									const tinygltf::Image &image = scene.images.at(tex.source);

									size_t s = image.image.size() * sizeof(TextureData);
									cudaMalloc(&dev_diffuseTex, s);
									cudaMemcpy(dev_diffuseTex, &image.image.at(0), s, cudaMemcpyHostToDevice);
									
									diffuseTexWidth = image.width;
									diffuseTexHeight = image.height;

									checkCUDAError("Set Texture Image data");
								}
							}
						}

						// TODO: write your code for other materails
						// You may have to take a look at tinygltfloader
						// You can also use the above code loading diffuse material as a start point 
					}


					// ---------Node hierarchy transform--------
					cudaDeviceSynchronize();
					
					dim3 numBlocksNodeTransform((numVertices + numThreadsPerBlock.x - 1) / numThreadsPerBlock.x);
					_nodeMatrixTransform << <numBlocksNodeTransform, numThreadsPerBlock >> > (
						numVertices,
						dev_position,
						dev_normal,
						matrix,
						matrixNormal);

					checkCUDAError("Node hierarchy transformation");

					// at the end of the for loop of primitive
					// push dev pointers to map
					primitiveVector.push_back(PrimitiveDevBufPointers{
						primitive.mode,
						primitiveType,
						numPrimitives,
						numIndices,
						numVertices,

						dev_indices,
						dev_position,
						dev_normal,
						dev_texcoord0,

						dev_diffuseTex,
						diffuseTexWidth,
						diffuseTexHeight,

						dev_vertexOut	//VertexOut
					});

					totalNumPrimitives += numPrimitives;

				} // for each primitive

			} // for each mesh

		} // for each node

	}
	

	// 3. Malloc for dev_primitives
	{
		cudaMalloc(&dev_primitives, totalNumPrimitives * sizeof(Primitive));
	}
	

	// Finally, cudaFree raw dev_bufferViews
	{

		std::map<std::string, BufferByte*>::const_iterator it(bufferViewDevPointers.begin());
		std::map<std::string, BufferByte*>::const_iterator itEnd(bufferViewDevPointers.end());
			
			//bufferViewDevPointers

		for (; it != itEnd; it++) {
			cudaFree(it->second);
		}

		checkCUDAError("Free BufferView Device Mem");
	}
}

__global__ 
void _vertexTransformAndAssembly(
	int numVertices, 
	PrimitiveDevBufPointers primitive, 
	glm::mat4 MVP, glm::mat4 MV, glm::mat3 MV_normal, 
	int width, int height) 
{

	// vertex id
	int vid = (blockIdx.x * blockDim.x) + threadIdx.x;
	if (vid < numVertices) {

		// TODO: Apply vertex transformation here
		// Multiply the MVP matrix for each vertex position, this will transform everything into clipping space
		// Then divide the pos by its w element to transform into NDC space
		// Finally transform x and y to viewport space

		// World coordinates
		glm::vec4 pWorld(primitive.dev_position[vid], 1.f);
		glm::vec3 norWorld(primitive.dev_normal[vid]);

		// Take point to homogenous coordinates/clip space
		glm::vec4 pClip = MVP * pWorld;
		// Take point to NDC
		pClip /= pClip.w;

		// Take point to screen space
		glm::vec4 pScreen(pClip);
		pScreen.x = ((pClip.x + 1.f) / 2.f) * (float)width;
		pScreen.y = ((1.f - pClip.y) / 2.f) * (float)height;
		pScreen.z = (-(pClip.z + 1.f) / 2.f);

		// Get the point's position in camera space
		glm::vec3 pEye(MV * pWorld);
		glm::vec3 norEye(glm::normalize(MV_normal * norWorld));

		// TODO: Apply vertex assembly here
		// Assemble all attribute arraies into the primitive array

		primitive.dev_verticesOut[vid].pos = pScreen;
		primitive.dev_verticesOut[vid].eyePos = pEye;
		primitive.dev_verticesOut[vid].eyeNor = norEye;

		// Texture stuff
		if (primitive.dev_diffuseTex == NULL) {
			primitive.dev_verticesOut[vid].dev_diffuseTex = NULL;
		}
		else {
			primitive.dev_verticesOut[vid].texcoord0 = primitive.dev_texcoord0[vid];
			primitive.dev_verticesOut[vid].dev_diffuseTex = primitive.dev_diffuseTex;
			primitive.dev_verticesOut[vid].texWidth = primitive.diffuseTexWidth;
			primitive.dev_verticesOut[vid].texHeight = primitive.diffuseTexHeight;
		}
	}
}


static int curPrimitiveBeginId = 0;

__global__ 
void _primitiveAssembly(int numIndices, int curPrimitiveBeginId, Primitive* dev_primitives, PrimitiveDevBufPointers primitive) {

	// index id
	int iid = (blockIdx.x * blockDim.x) + threadIdx.x;

	if (iid < numIndices) {

		// TODO: uncomment the following code for a start
		// This is primitive assembly for triangles

		int pid;	// id for cur primitives vector
		if (primitive.primitiveMode == TINYGLTF_MODE_TRIANGLES) {
			pid = iid / (int)primitive.primitiveType;
			dev_primitives[pid + curPrimitiveBeginId].v[iid % (int)primitive.primitiveType]
				= primitive.dev_verticesOut[primitive.dev_indices[iid]];
		} 
		else if (primitive.primitiveMode == TINYGLTF_MODE_POINTS) {
			
		}
		else if (primitive.primitiveMode == TINYGLTF_MODE_LINE) {
			
		}

		// TODO: other primitive types (point, line)
	}
}

// http://groups.csail.mit.edu/graphics/classes/6.837/F02/lectures/6.837-7_Line.pdf
__device__
void _rasterizeLine(int width, int height,
	Fragment *dev_fragmentBuffer,
	glm::vec3 &p1, glm::vec3 &p2)
{
	int x1 = p1.x;
	int x2 = p2.x;
	int y1 = p1.y;
	int y2 = p2.y;

	int dx = x2 - x1;
	int dy = y2 - y1;
	float m = dy / dx;

	for (int x = x1; x <= x2; x++) {
		int y = y1 + (int)m * (x - x1);

		int index = x + (y * width);
		if (x <= width - 1 && x >= 0 && y <= height - 1 && height >= 0)
			dev_fragmentBuffer[index].color = glm::vec3(1.f, 0.f, 0.f);
	}
}

__device__
void _rasterizePoints(int width, int height, glm::vec3 *triPos, Fragment *dev_fragmentBuffer)
{
	// Since we only need to draw the points
	// we can just set a color for each of the 
	// points on the triangle. 
	// For whatever reason, I couldn't set the color during render()
	for (int i = 0; i < 3; i++) {
		int x = triPos[i].x;
		int y = triPos[i].y;

		int index = x + (y * width);
		dev_fragmentBuffer[index].color = glm::vec3(0.f, 1.f, 1.f);
	}
}

struct cullPrim
{
	__host__ __device__
	bool operator()(const Primitive &prim)
	{
		glm::vec3 triEyePos[3];
		triEyePos[0] = prim.v[0].eyePos;
		triEyePos[1] = prim.v[1].eyePos;
		triEyePos[2] = prim.v[2].eyePos;

		glm::vec3 triEyeNor[3];
		triEyeNor[0] = prim.v[0].eyeNor;
		triEyeNor[1] = prim.v[1].eyeNor;
		triEyeNor[2] = prim.v[2].eyeNor;

		return (glm::dot(triEyePos[0], triEyeNor[0]) >= 0.f);
	}
};

__global__ 
void _rasterize(int numPrims, int width, int height,
				Primitive *dev_primitives, 
				Fragment *dev_fragmentBuffer,
				int *dev_depth, int *dev_mutex)
{
	// Primitive ID
	int pid = (blockIdx.x * blockDim.x) + threadIdx.x;
	if (pid < numPrims) {
		Primitive prim = dev_primitives[pid];
		
		glm::vec3 triPos[3];
		triPos[0] = glm::vec3(prim.v[0].pos);
		triPos[1] = glm::vec3(prim.v[1].pos);
		triPos[2] = glm::vec3(prim.v[2].pos);

		glm::vec3 triEyePos[3];
		triEyePos[0] = prim.v[0].eyePos;
		triEyePos[1] = prim.v[1].eyePos;
		triEyePos[2] = prim.v[2].eyePos;

		glm::vec3 triEyeNor[3];
		triEyeNor[0] = prim.v[0].eyeNor;
		triEyeNor[1] = prim.v[1].eyeNor;
		triEyeNor[2] = prim.v[2].eyeNor;

		//int culledPrims = numPrims;
		//if (BACKFACE_CULLING) {
		//	Primitive *unculledPrims = thrust::partition(thrust::device, dev_primitives, dev_primitives + culledPrims, cullPrim());
		//	culledPrims = unculledPrims - dev_primitives;
		//}

		// https://en.wikipedia.org/wiki/Back-face_culling
		if (glm::dot(triEyePos[0], triEyeNor[0]) >= 0.f && BACKFACE_CULLING) {
			return;
		}

		// Get bounding box for the primitive
		AABB triBB = getAABBForTriangle(triPos);

#if DRAWPOINTS
		// Pass in triangle and draw each point
		_rasterizePoints(width, height, triPos, dev_fragmentBuffer);
#elif DRAWLINES
		// Pass in 2 points of a triangle and draw the line connecting them
		_rasterizeLine(width, height, dev_fragmentBuffer, triPos[0], triPos[1]);
		_rasterizeLine(width, height, dev_fragmentBuffer, triPos[1], triPos[2]);
		_rasterizeLine(width, height, dev_fragmentBuffer, triPos[2], triPos[0]);
// Triangles
#else 
		for (int i = triBB.min.x; i < triBB.max.x; i++) {
			for (int j = triBB.min.y; j < triBB.max.y; j++) {
				// Get the barycentric coordinate 
				glm::vec2 pixel(i, j);
				glm::vec3 p = calculateBarycentricCoordinate(triPos, pixel);

				// Check to see if the point is in the triangle
				if (isBarycentricCoordInBounds(p)) {
					int index = i + (j * width);
					
					bool isLocked = false;
#if MUTEX
					do
					{
						isLocked = (atomicCAS(&dev_mutex[index], 0, 1) == 0);
#endif		// end mutex
						// Get the z coordinate and scale by some factor
						int depth = getZAtCoordinate(p, triPos) * INT_MAX;

						// Store the resulting minimum depth at dev_depth[index]
						atomicMin(&dev_depth[index], depth);

						// Need to check if the the current depth is the closest one
						if (dev_depth[index] == depth) {
							// Color point if in bounds
							dev_fragmentBuffer[index].color = glm::vec3(1.f);
							dev_fragmentBuffer[index].eyePos = triEyePos[0] * p.x + triEyePos[1] * p.y + triEyePos[2] * p.z;
							dev_fragmentBuffer[index].eyeNor = triEyeNor[0] * p.x + triEyeNor[1] * p.y + triEyeNor[2] * p.z;

							// Texture stuff
							dev_fragmentBuffer[index].dev_diffuseTex = prim.v[0].dev_diffuseTex;
							dev_fragmentBuffer[index].diffuseTexWidth = prim.v[0].texWidth;
							dev_fragmentBuffer[index].diffuseTexHeight = prim.v[0].texHeight;
							dev_fragmentBuffer[index].texcoord0 = p.x * prim.v[0].texcoord0 + p.y * prim.v[1].texcoord0 + p.z * prim.v[2].texcoord0;

							if (PERPSECTIVE_CORRECT) {
								// Perspective Correct Texture Coordinate
								// Divide all attributes (in this case barycentric) by eye space z
								// https://www.scratchapixel.com/lessons/3d-basic-rendering/rasterization-practical-implementation/perspective-correct-interpolation-vertex-attributes
								glm::vec3 w(p.x / triEyePos[0].z, p.y / triEyePos[1].z, p.z / triEyePos[2].z);

								float s = w.x * prim.v[0].texcoord0.x + w.y * prim.v[1].texcoord0.x + w.z * prim.v[2].texcoord0.x;
								float t = w.x * prim.v[0].texcoord0.y + w.y * prim.v[1].texcoord0.y + w.z * prim.v[2].texcoord0.y;

								float z = 1.f / (w.x + w.y + w.z);
								s *= z;
								t *= z;

								dev_fragmentBuffer[index].texcoord0 = glm::vec2(s, t);
							}
						}
#if MUTEX
						if (isLocked && MUTEX) {
							dev_mutex[index] = 0;
						}
					} while (!isLocked);
#endif		// end mutex
				}
			}
		}
#endif
	}
}



/**
 * Perform rasterization.
 */
void rasterize(uchar4 *pbo, const glm::mat4 & MVP, const glm::mat4 & MV, const glm::mat3 MV_normal) {
	StreamCompaction::Common::PerformanceTimer vertexTransformTimer;
	StreamCompaction::Common::PerformanceTimer primitiveAssemblyTimer;
	StreamCompaction::Common::PerformanceTimer rasterizationTimer;
	StreamCompaction::Common::PerformanceTimer renderTimer;

    int sideLength2d = 8;
    dim3 blockSize2d(sideLength2d, sideLength2d);
    dim3 blockCount2d((width  - 1) / blockSize2d.x + 1,
		(height - 1) / blockSize2d.y + 1);

	// Execute your rasterization pipeline here
	// (See README for rasterization pipeline outline.)

	// Vertex Process & primitive assembly
	{
		curPrimitiveBeginId = 0;
		dim3 numThreadsPerBlock(128);

		auto it = mesh2PrimitivesMap.begin();
		auto itEnd = mesh2PrimitivesMap.end();

		float vertTotal = 0.f;
		float assembleTotal = 0.f;

		for (; it != itEnd; ++it) {
			auto p = (it->second).begin();	// each primitive
			auto pEnd = (it->second).end();
			for (; p != pEnd; ++p) {
				dim3 numBlocksForVertices((p->numVertices + numThreadsPerBlock.x - 1) / numThreadsPerBlock.x);
				dim3 numBlocksForIndices((p->numIndices + numThreadsPerBlock.x - 1) / numThreadsPerBlock.x);

				vertexTransformTimer.startGpuTimer();
				_vertexTransformAndAssembly << < numBlocksForVertices, numThreadsPerBlock >> >(p->numVertices, *p, MVP, MV, MV_normal, width, height);
				vertexTransformTimer.endGpuTimer();
				vertTotal += vertexTransformTimer.getGpuElapsedTimeForPreviousOperation();
				checkCUDAError("Vertex Processing");
				cudaDeviceSynchronize();
				
				primitiveAssemblyTimer.startGpuTimer();
				_primitiveAssembly << < numBlocksForIndices, numThreadsPerBlock >> >
					(p->numIndices, 
					curPrimitiveBeginId, 
					dev_primitives, 
					*p);
				primitiveAssemblyTimer.endGpuTimer();
				assembleTotal += primitiveAssemblyTimer.getGpuElapsedTimeForPreviousOperation();
				checkCUDAError("Primitive Assembly");

				curPrimitiveBeginId += p->numPrimitives;
			}
		}
		
		printf("Vertex Transformation: %f\n", vertexTransformTimer.getGpuElapsedTimeForPreviousOperation());
		printf("Primitive Assembly: %f\n", primitiveAssemblyTimer.getGpuElapsedTimeForPreviousOperation());

		checkCUDAError("Vertex Processing and Primitive Assembly");
	}
	
	cudaMemset(dev_fragmentBuffer, 0, width * height * sizeof(Fragment));
	initDepth << <blockCount2d, blockSize2d >> >(width, height, dev_depth);
	
	// TODO: rasterize
	
	{
		dim3 numThreadsPerBlock(128);
		dim3 numBlocksForPrims((totalNumPrimitives + numThreadsPerBlock.x - 1) / numThreadsPerBlock.x);

		rasterizationTimer.startGpuTimer();
		_rasterize << < numBlocksForPrims, numThreadsPerBlock >> > (totalNumPrimitives, width, height, dev_primitives, dev_fragmentBuffer, dev_depth, dev_mutex);
		rasterizationTimer.endGpuTimer();
		printf("Rasterization: %f\n", rasterizationTimer.getGpuElapsedTimeForPreviousOperation());
		
		checkCUDAError("rasterization");
	}
	

    // Copy depthbuffer colors into framebuffer
	renderTimer.startGpuTimer();
	render << <blockCount2d, blockSize2d >> >(width, height, dev_fragmentBuffer, dev_framebuffer);
	renderTimer.endGpuTimer();
	printf("Render: %f\n", renderTimer.getGpuElapsedTimeForPreviousOperation());

	checkCUDAError("fragment shader");
    // Copy framebuffer into OpenGL buffer for OpenGL previewing
    sendImageToPBO<<<blockCount2d, blockSize2d>>>(pbo, width, height, dev_framebuffer);
    checkCUDAError("copy render result to pbo");
}

/**
 * Called once at the end of the program to free CUDA memory.
 */
void rasterizeFree() {

    // deconstruct primitives attribute/indices device buffer

	auto it(mesh2PrimitivesMap.begin());
	auto itEnd(mesh2PrimitivesMap.end());
	for (; it != itEnd; ++it) {
		for (auto p = it->second.begin(); p != it->second.end(); ++p) {
			cudaFree(p->dev_indices);
			cudaFree(p->dev_position);
			cudaFree(p->dev_normal);
			cudaFree(p->dev_texcoord0);
			cudaFree(p->dev_diffuseTex);

			cudaFree(p->dev_verticesOut);

			
			//TODO: release other attributes and materials
		}
	}

	////////////

    cudaFree(dev_primitives);
    dev_primitives = NULL;

	cudaFree(dev_fragmentBuffer);
	dev_fragmentBuffer = NULL;

    cudaFree(dev_framebuffer);
    dev_framebuffer = NULL;

	cudaFree(dev_depth);
	dev_depth = NULL;

	cudaFree(dev_mutex);
	dev_mutex = NULL;

    checkCUDAError("rasterize Free");
}
