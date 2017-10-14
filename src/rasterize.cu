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

static const int DEPTHSCALE = 10000;
#define SCANLINE 1 // the other technique is using the edge Function
#define DISPLAY_DEPTH 0
#define DISPLAY_NORMAL 0
#define DISPLAY_ABSNORMAL 0
#define FRAG_SHADING_LAMBERT 1
#define BILINEAR_FILTERING 1

namespace 
{
	typedef unsigned short VertexIndex;
	typedef glm::vec3 VertexAttributePosition;
	typedef glm::vec3 VertexAttributeNormal;
	typedef glm::vec2 VertexAttributeTexcoord;
	typedef unsigned char TextureData;

	typedef unsigned char BufferByte;

	enum PrimitiveType
	{
		Point = 1,
		Line = 2,
		Triangle = 3
	};

	struct VertexOut 
	{
		glm::vec4 vPos;
		glm::vec3 vEyePos;	// eye space position used for shading
		glm::vec3 vNor;	// eye space normal used for shading, cuz normal will go wrong after perspective transformation
		glm::vec3 vColor;
		glm::vec2 texcoord0;
		TextureData* dev_diffuseTex = NULL;
		int texWidth, texHeight;
	};

	struct Primitive 
	{
		PrimitiveType primitiveType = Triangle;	// C++ 11 init
		VertexOut v[3];
	};

	struct Fragment 
	{
		glm::vec3 fColor;
		glm::vec3 fEyePos;	// eye space position used for shading
		glm::vec3 fNor;
		float depth;
		VertexAttributeTexcoord texcoord0;
		TextureData* dev_diffuseTex;
	};

	struct PrimitiveDevBufPointers 
	{
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
static int * dev_depth = NULL; //depth buffer
static int * dev_mutex = NULL; //mutex buffer for depth

/**
 * Kernel that writes the image to the OpenGL PBO directly.
 */
__global__ void sendImageToPBO(uchar4 *pbo, int w, int h, glm::vec3 *image) 
{
    int x = (blockIdx.x * blockDim.x) + threadIdx.x;
    int y = (blockIdx.y * blockDim.y) + threadIdx.y;
    int index = x + (y * w);

    if (x < w && y < h) 
	{
        glm::vec3 fcolor;
        fcolor.x = glm::clamp(image[index].x, 0.0f, 1.0f) * 255.0;
        fcolor.y = glm::clamp(image[index].y, 0.0f, 1.0f) * 255.0;
        fcolor.z = glm::clamp(image[index].z, 0.0f, 1.0f) * 255.0;
        // Each thread writes one pixel location in the texture (textel)
        pbo[index].w = 0;
        pbo[index].x = fcolor.x;
        pbo[index].y = fcolor.y;
        pbo[index].z = fcolor.z;
    }
}

__host__ __device__ glm::vec3 LambertFragShader(glm::vec3 pos, glm::vec3 color, glm::vec3 normal)
{
	glm::vec3 finalColor;
	glm::vec3 lightPosition = glm::vec3(10,20,10);
	glm::vec3 lightVec = glm::normalize(lightPosition - pos);
	
	glm::vec3 ambientLightColor = glm::vec3(0.2f, 0.2f, 0.2f);
	float dot = glm::clamp(glm::dot(lightVec, normal), 0.0f, 1.0f);
	
	finalColor = color *dot + 0.05f;
	return glm::clamp(finalColor, 0.0f, 1.0f);
}

/** 
* Writes fragment colors to the framebuffer
*/
__global__ void render(int w, int h, Fragment *fragmentBuffer, glm::vec3 *framebuffer) 
{
    int x = (blockIdx.x * blockDim.x) + threadIdx.x;
    int y = (blockIdx.y * blockDim.y) + threadIdx.y;
    int index = x + (y * w);

    if (x < w && y < h) 
	{
#if DISPLAY_DEPTH
		framebuffer[index] = glm::vec3(fragmentBuffer[index].depth);
#elif DISPLAY_NORMAL
		framebuffer[index] = fragmentBuffer[index].fNor;
#elif DISPLAY_ABSNORMAL
		framebuffer[index] = glm::abs(fragmentBuffer[index].fNor);
#elif FRAG_SHADING_LAMBERT
		framebuffer[index] = LambertFragShader(fragmentBuffer[index].fEyePos,
											   fragmentBuffer[index].fColor,
											   fragmentBuffer[index].fNor);
#else
		framebuffer[index] = fragmentBuffer[index].fColor + 0.15f;
#endif
    }
}

/**
 * Called once at the beginning of the program to allocate memory.
 */
void rasterizeInit(int w, int h) 
{
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
	cudaMalloc(&dev_mutex, sizeof(int));
	
	checkCUDAError("rasterizeInit");
}

__global__ void initDepth(int w, int h, int * depth)
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
void _deviceBufferCopy(int N, BufferByte* dev_dst, const BufferByte* dev_src, int n, int byteStride, int byteOffset, int componentTypeByteSize) 
{
	// Attribute (vec3 position)
	// component (3 * float)
	// byte (4 * byte)

	// id of component
	int i = (blockIdx.x * blockDim.x) + threadIdx.x;

	if (i < N) 
	{
		int count = i / n;
		int offset = i - count * n;	// which component of the attribute

		for (int j = 0; j < componentTypeByteSize; j++) 
		{
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
void _nodeMatrixTransform( int numVertices,
						   VertexAttributePosition* position,
						   VertexAttributeNormal* normal,
						   glm::mat4 MV, glm::mat3 MV_normal) 
{
	// vertex id
	int vid = (blockIdx.x * blockDim.x) + threadIdx.x;
	if (vid < numVertices) 
	{
		position[vid] = glm::vec3(MV * glm::vec4(position[vid], 1.0f));
		normal[vid] = glm::normalize(MV_normal * normal[vid]);
	}
}

glm::mat4 getMatrixFromNodeMatrixVector(const tinygltf::Node & n) 
{
	glm::mat4 curMatrix(1.0);

	const std::vector<double> &m = n.matrix;
	if (m.size() > 0) 
	{
		// matrix, copy it
		for (int i = 0; i < 4; i++) 
		{
			for (int j = 0; j < 4; j++) 
			{
				curMatrix[i][j] = (float)m.at(4 * i + j);
			}
		}
	} 
	else 
	{
		// no matrix, use rotation, scale, translation
		if (n.translation.size() > 0) 
		{
			curMatrix[3][0] = n.translation[0];
			curMatrix[3][1] = n.translation[1];
			curMatrix[3][2] = n.translation[2];
		}

		if (n.rotation.size() > 0) 
		{
			glm::mat4 R;
			glm::quat q;
			q[0] = n.rotation[0];
			q[1] = n.rotation[1];
			q[2] = n.rotation[2];

			R = glm::mat4_cast(q);
			curMatrix = curMatrix * R;
		}

		if (n.scale.size() > 0) 
		{
			curMatrix = curMatrix * glm::scale(glm::vec3(n.scale[0], n.scale[1], n.scale[2]));
		}
	}

	return curMatrix;
}

void traverseNode (	std::map<std::string, glm::mat4> & n2m,
					const tinygltf::Scene & scene,
					const std::string & nodeString,
					const glm::mat4 & parentMatrix ) 
{
	const tinygltf::Node & n = scene.nodes.at(nodeString);
	glm::mat4 M = parentMatrix * getMatrixFromNodeMatrixVector(n);
	n2m.insert(std::pair<std::string, glm::mat4>(nodeString, M));

	auto it = n.children.begin();
	auto itEnd = n.children.end();

	for (; it != itEnd; ++it) 
	{
		traverseNode(n2m, scene, *it, M);
	}
}

void rasterizeSetBuffers(const tinygltf::Scene & scene) 
{
	totalNumPrimitives = 0;

	std::map<std::string, BufferByte*> bufferViewDevPointers;

	// 1. copy all `bufferViews` to device memory
	{
		std::map<std::string, tinygltf::BufferView>::const_iterator it(
			scene.bufferViews.begin());
		std::map<std::string, tinygltf::BufferView>::const_iterator itEnd(
			scene.bufferViews.end());

		for (; it != itEnd; it++) 
		{
			const std::string key = it->first;
			const tinygltf::BufferView &bufferView = it->second;
			if (bufferView.target == 0) 
			{
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
					_deviceBufferCopy <<<numBlocks, numThreadsPerBlock>>> ( numIndices,
																			(BufferByte*)dev_indices,
																			dev_bufferView,
																			n,
																			indexAccessor.byteStride,
																			indexAccessor.byteOffset,
																			componentTypeByteSize );


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
					for (; it != itEnd; it++) 
					{
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

						_deviceBufferCopy <<<numBlocks, numThreadsPerBlock>>> ( n * numVertices,
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

__global__ void _vertexTransformAndAssembly( int numVertices, 
											PrimitiveDevBufPointers primitive, 
											glm::mat4 MVP, glm::mat4 MV, glm::mat3 MV_normal, 
											int width, int height ) 
{
	// vertex id
	int vid = (blockIdx.x * blockDim.x) + threadIdx.x;
	if (vid < numVertices) 
	{
		//---------------------------------------------------
		//-------------- Vertex Transformation --------------
		//---------------------------------------------------
		// Multiply the MVP matrix for each vertex position, this will transform everything into clipping space
		// Then divide the pos by its w element to transform into NDC space
		// Finally transform x and y to viewport space
		glm::vec4 vPos = glm::vec4(primitive.dev_position[vid], 1.0f);
		glm::vec4 eyePos = MV*vPos;
		vPos = MVP*vPos; //now things are in clip space
		vPos /= vPos.w; //now things are in NDC space
		vPos.x = (vPos.x + 1.0f)*float(width)*0.5f;
		vPos.y = (1.0f - vPos.y)*float(height)*0.5f; //now in pixel space or window coordinates
		
		vPos.z = -(vPos.z + 1.0f)*0.5f; // to convert z from a 1 to -1 range to a 0 to 1 range

		glm::vec3 vNor = primitive.dev_normal[vid];
		vNor = glm::normalize(MV_normal*vNor);
		//---------------------------------------------------
		//-------------- Vertex assembly --------------------
		//---------------------------------------------------
		// Assemble all attribute arrays into the primitive array
		primitive.dev_verticesOut[vid].vPos = vPos;
		primitive.dev_verticesOut[vid].vNor = vNor;
		primitive.dev_verticesOut[vid].vEyePos = glm::vec3(eyePos);
		primitive.dev_verticesOut[vid].vColor = glm::vec3(0,1,0);

		// Texture Mapping
		if (primitive.dev_diffuseTex == NULL) 
		{
			primitive.dev_verticesOut[vid].dev_diffuseTex = NULL;
		}
		else 
		{
			primitive.dev_verticesOut[vid].texcoord0 = primitive.dev_texcoord0[vid];
			primitive.dev_verticesOut[vid].dev_diffuseTex = primitive.dev_diffuseTex;
			primitive.dev_verticesOut[vid].texWidth = primitive.diffuseTexWidth;
			primitive.dev_verticesOut[vid].texHeight = primitive.diffuseTexHeight;
		}
	}
}

static int curPrimitiveBeginId = 0;

__global__ void _primitiveAssembly(int numIndices, int curPrimitiveBeginId, 
						Primitive* dev_primitives, PrimitiveDevBufPointers primitive) 
{
	// index id
	int iid = (blockIdx.x * blockDim.x) + threadIdx.x;

	if (iid < numIndices) 
	{
		// This is primitive assembly for triangles
		int pid;	// id for cur primitives vector
		if (primitive.primitiveMode == TINYGLTF_MODE_TRIANGLES) 
		{
			pid = iid / (int)primitive.primitiveType;
			dev_primitives[pid + curPrimitiveBeginId].v[iid % (int)primitive.primitiveType]
				= primitive.dev_verticesOut[primitive.dev_indices[iid]];
		}

		// TODO: other primitive types (point, line)
	}
}


__host__ __device__ static
glm::vec3 getTextureColorAt(const TextureData* texture, const int& textureWidth, int& u, int& v)
{
	int flatIndex = (u + v * textureWidth) * 3;
	float r = (float)texture[flatIndex] / 255.0f; //flatIndex * 3 --> because 3 color channels
	float g = (float)texture[flatIndex + 1] / 255.0f;
	float b = (float)texture[flatIndex + 2] / 255.0f;
	return glm::vec3(r, g, b);
}

__host__ __device__ static
glm::vec3 getBilinearFilteredColor(const TextureData* tex,
								   const int &texWidth, const int &texHeight,
								   const float &u, const float &v)
{
	//references: 
	//https://en.wikipedia.org/wiki/Bilinear_filtering
	//https://www.scratchapixel.com/lessons/mathematics-physics-for-computer-graphics/interpolation/bilinear-filtering
	float x = u * (float)texWidth;
	float y = v * (float)texHeight;
	float floorX = glm::floor(x);
	float floorY = glm::floor(y);
	float deltaX = x - floorX;
	float deltaY = y - floorY;

	//get the square for which we will perform bilinear interpolation
	int xPos = (int)floorX;
	int yPos = (int)floorY;
	int xPlusOne = glm::clamp(xPos + 1, 0, texWidth - 1);
	int yPlusOne = glm::clamp(yPos + 1, 0, texHeight - 1);

	//get 4 color values
	glm::vec3 c00 = getTextureColorAt(tex, texWidth, xPos, yPos);
	glm::vec3 c10 = getTextureColorAt(tex, texWidth, xPlusOne, yPos);
	glm::vec3 c01 = getTextureColorAt(tex, texWidth, xPos, yPlusOne);
	glm::vec3 c11 = getTextureColorAt(tex, texWidth, xPlusOne, yPlusOne);

	//bilinear interpolation between the above 4 colors
	glm::vec3 c20 = glm::mix(c00, c10, deltaX);
	glm::vec3 c21 = glm::mix(c01, c11, deltaX);
	return glm::mix(c20, c21, deltaY);
}


__host__ __device__ void modifyFragment(Primitive* dev_primitives, Fragment* dev_fragments, 
										int* dev_depthBuffer, float& z,
										glm::vec3 tri[3], glm::vec3 baryCoords,
										int& index, int& fragIndex)
{
	//for perspective correct interpolation you need the z values
	float z1 = -tri[0].z;
	float z2 = -tri[1].z;
	float z3 = -tri[2].z;

	glm::vec3 v0eyePos = dev_primitives[index].v[0].vEyePos;
	glm::vec3 v1eyePos = dev_primitives[index].v[1].vEyePos;
	glm::vec3 v2eyePos = dev_primitives[index].v[2].vEyePos;

	glm::vec3 v0color = dev_primitives[index].v[0].vColor;
	glm::vec3 v1color = dev_primitives[index].v[1].vColor;
	glm::vec3 v2color = dev_primitives[index].v[2].vColor;

	glm::vec3 v0Nor = dev_primitives[index].v[0].vNor;
	glm::vec3 v1Nor = dev_primitives[index].v[1].vNor;
	glm::vec3 v2Nor = dev_primitives[index].v[2].vNor;

	glm::vec2 v0UV = dev_primitives[index].v[0].texcoord0;
	glm::vec2 v1UV = dev_primitives[index].v[1].texcoord0;
	glm::vec2 v2UV = dev_primitives[index].v[2].texcoord0;

	TextureData* triangleDiffuseTex = dev_primitives[index].v[0].dev_diffuseTex;

	//if testing Depth coloration
	dev_fragments[fragIndex].dev_diffuseTex = triangleDiffuseTex;
	dev_fragments[fragIndex].depth = dev_depthBuffer[fragIndex]/float(DEPTHSCALE);
	dev_fragments[fragIndex].fNor = z*((v0Nor / z1)*baryCoords.x + 
									   (v1Nor / z2)*baryCoords.y + 
									   (v2Nor / z3)*baryCoords.z );
	dev_fragments[fragIndex].texcoord0 = z*((v0UV / z1)*baryCoords.x +
										    (v0UV / z2)*baryCoords.y +
										    (v0UV / z3)*baryCoords.z);

	if (dev_fragments[fragIndex].dev_diffuseTex != NULL)
	{
#if BILINEAR_FILTERING
		dev_fragments[fragIndex].fColor = getBilinearFilteredColor(dev_fragments[fragIndex].dev_diffuseTex,
																   dev_primitives[index].v[0].texWidth,
																   dev_primitives[index].v[0].texHeight,
																   dev_fragments[fragIndex].texcoord0[0],
																   dev_fragments[fragIndex].texcoord0[1]);
#else
		int u = dev_fragments[fragIndex].texcoord0[0] * dev_primitives[index].v[0].texWidth;
		int v = dev_fragments[fragIndex].texcoord0[1] * dev_primitives[index].v[0].texHeight;
		dev_fragments[fragIndex].fColor = getTextureColorAt(dev_fragments[fragIndex].dev_diffuseTex,
															dev_primitives[index].v[0].texWidth, u, v);
#endif
	}
	else
	{
		dev_fragments[fragIndex].fColor = z*((v0color / z1)*baryCoords.x +
											 (v1color / z2)*baryCoords.y +
											 (v2color / z3)*baryCoords.z);
	}

	//to make the normals follow convention:
	//z is positive coming out of the screen
	//x is positive to the right
	//y is positive going up
	dev_fragments[fragIndex].fNor.x *= -1.0f;

	//clamp color and normals values
	dev_fragments[fragIndex].fNor.x = glm::clamp(dev_fragments[fragIndex].fNor.x, 0.0f, 1.0f);
	dev_fragments[fragIndex].fNor.y = glm::clamp(dev_fragments[fragIndex].fNor.y, 0.0f, 1.0f);
	dev_fragments[fragIndex].fNor.z = glm::clamp(dev_fragments[fragIndex].fNor.z, 0.0f, 1.0f);

	dev_fragments[fragIndex].fColor.x = glm::clamp(dev_fragments[fragIndex].fColor.x, 0.0f, 1.0f);
	dev_fragments[fragIndex].fColor.y = glm::clamp(dev_fragments[fragIndex].fColor.y, 0.0f, 1.0f);
	dev_fragments[fragIndex].fColor.z = glm::clamp(dev_fragments[fragIndex].fColor.z, 0.0f, 1.0f);
}

__global__ void _rasterize(int w, int h, int numTriangles, Primitive* dev_primitives, 
							Fragment* dev_fragments, int* dev_depthBuffer, int* dev_mutex)
{
	int index = (blockIdx.x * blockDim.x) + threadIdx.x;

	if (index < numTriangles)
	{
		glm::vec3 tri[3];
		tri[0] = glm::vec3(dev_primitives[index].v[0].vPos);
		tri[1] = glm::vec3(dev_primitives[index].v[1].vPos);
		tri[2] = glm::vec3(dev_primitives[index].v[2].vPos);
		AABB boundingBox = getAABBForTriangle(tri);

		for (int y = boundingBox.min.y; y <= boundingBox.max.y; ++y)
		{
			for (int x = boundingBox.min.x; x <= boundingBox.max.x; ++x)
			{
#if SCANLINE
				//scanline Implementation
				glm::vec3 baryCoords = calculateBarycentricCoordinate(tri, glm::vec2(x,y));
				bool isInsideTriangle = isBarycentricCoordInBounds(baryCoords);
				if(isInsideTriangle)
				{
					int fragIndex = x + y*w;

					//multiplying z value by a large static int because atomicCAS is only defined for ints
					//and atomicCAS is needed to handle race conditions along with the mutex lock
					float z = getZAtCoordinate(baryCoords, tri);
					int scaledZ = z*DEPTHSCALE;

					bool isSet;
					do {
						isSet = (atomicCAS(dev_mutex, 0, 1) == 0);
						if (isSet) 
						{
							// Critical section goes here.
							// if it is afterward, a deadlock will occur.
							if (scaledZ < dev_depthBuffer[fragIndex])
							{
								dev_depthBuffer[fragIndex] = scaledZ;
								modifyFragment(dev_primitives, dev_fragments, dev_depthBuffer, z,
														tri, baryCoords, index, fragIndex);
							}

							*dev_mutex = 0;
						}
					} while (!isSet);
				}
#else
				////edgefunction implementation
				glm::vec2 point = glm::vec2(x,y);
				if (IsPointInsideTriangle(tri[0], tri[1], tri[2], point))
				{
					int fragIndex = x + y*w;
					dev_fragments[fragIndex].color = glm::vec3(0,1,0);
				}
#endif
			}
		}
	}
}

//Perform rasterization.
void rasterize(uchar4 *pbo, const glm::mat4 & MVP, const glm::mat4 & MV, const glm::mat3 MV_normal) 
{
    int sideLength2d = 8;
    dim3 blockSize2d(sideLength2d, sideLength2d);
    dim3 blockCount2d((width  - 1) / blockSize2d.x + 1,
		(height - 1) / blockSize2d.y + 1);

	//----------------------------------------------------------
	//----------------- Rasterization pipeline------------------
	//----------------------------------------------------------
	// Vertex Process & primitive assembly
	{
		curPrimitiveBeginId = 0;
		dim3 numThreadsPerBlock(128);

		auto it = mesh2PrimitivesMap.begin();
		auto itEnd = mesh2PrimitivesMap.end();

		for (; it != itEnd; ++it) 
		{
			auto p = (it->second).begin();	// each primitive
			auto pEnd = (it->second).end();
			for (; p != pEnd; ++p) 
			{
				dim3 numBlocksForVertices((p->numVertices + numThreadsPerBlock.x - 1) / numThreadsPerBlock.x);
				dim3 numBlocksForIndices((p->numIndices + numThreadsPerBlock.x - 1) / numThreadsPerBlock.x);

				_vertexTransformAndAssembly <<<numBlocksForVertices, numThreadsPerBlock>>>(p->numVertices, *p, MVP, MV,
																							MV_normal, width, height);
				checkCUDAError("Vertex Processing");
				cudaDeviceSynchronize();
				_primitiveAssembly <<<numBlocksForIndices, numThreadsPerBlock>>> (p->numIndices, curPrimitiveBeginId, 
																						dev_primitives, *p);
				checkCUDAError("Primitive Assembly");

				curPrimitiveBeginId += p->numPrimitives;
			}
		}

		checkCUDAError("Vertex Processing and Primitive Assembly");
	}
	
	cudaMemset(dev_mutex, 0, sizeof(int));//mutex for depth buffer
	cudaMemset(dev_fragmentBuffer, 0, width * height * sizeof(Fragment));
	initDepth <<<blockCount2d, blockSize2d >>>(width, height, dev_depth);
		
	// rasterize --> looping over all primitives(triangles)
	dim3 numThreadsPerBlock(128);
	dim3 blockSize1d((totalNumPrimitives - 1) / numThreadsPerBlock.x + 1);
	_rasterize <<<blockSize1d, numThreadsPerBlock>>>(width, height, totalNumPrimitives, 
													dev_primitives, dev_fragmentBuffer,
													dev_depth, dev_mutex);

    // Copy depthbuffer colors into framebuffer
	render <<<blockCount2d, blockSize2d >>>(width, height, dev_fragmentBuffer, dev_framebuffer);
	checkCUDAError("fragment shader");
    // Copy framebuffer into OpenGL buffer for OpenGL previewing
    sendImageToPBO<<<blockCount2d, blockSize2d>>>(pbo, width, height, dev_framebuffer);
    checkCUDAError("copy render result to pbo");
}

/**
 * Called once at the end of the program to free CUDA memory.
 */
void rasterizeFree() 
{
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
	dev_depth = NULL;

    checkCUDAError("rasterize Free");
}
