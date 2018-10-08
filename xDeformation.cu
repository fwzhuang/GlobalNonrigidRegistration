#include "stdafx.h"

#include "xDeformation.h"

#include "xDeformation/Cuda/xDeformationCudaFuncs.cuh"
#include "Helpers/xUtils.h"
#include "Helpers/UtilsMath.h"
#include "Helpers/InnorealTimer.hpp"
#include "Helpers/xGlobalStats.h"
#include "xMeshEdgeSample/xPointCloudEdgeSample.hpp"
#include "SiftGPU/xSift.h"
#include "GMS/xGMS.h"

#include <cassert>
#include <glm/glm.hpp>
#include <glm/gtc/matrix_transform.hpp>
#include <glm/gtc/type_ptr.hpp>
#include <windows.h>
//#include <Eigen/Eigen>
#include "GNSolver.h"
#include "InputData.h"

xDeformation::xDeformation(int& fragIdx, VBOType* dVboCuda)
	: m_dVboCuda(dVboCuda),
	  m_fragIdx(fragIdx),
	  m_width(Resolution::getInstance().width()),
	  m_height(Resolution::getInstance().height()),
	  m_loopClosureNum(0),
	  m_matchingPointNum(0),
	  m_matchingPointsNumDescriptor(0),
	  m_matchingPointsNumNearest(0)
{
	srand((unsigned)time(NULL));

	allocEssentialCUDAMemory();

	m_isFragValid = std::vector<int>(MAX_FRAG_NUM, 3);

	//m_grayImgDevice = cv::cuda::GpuMat(m_height, m_width, CV_8UC1);
	m_dVerticalBlurImg = cv::cuda::GpuMat(m_height, m_width, CV_32FC1);
	m_dHorizontalBlurImg = cv::cuda::GpuMat(m_height, m_width, CV_32FC1);

	cv::getDerivKernels(m_kxRow, m_kyRow, 1, 0, CV_SCHARR, true);
	cv::getDerivKernels(m_kxCol, m_kyCol, 0, 1, CV_SCHARR, true);
#if 0
	std::cout << m_kx_row << std::endl;
	std::cout << m_ky_row << std::endl;
	std::cout << m_kx_col << std::endl;
	std::cout << m_ky_col << std::endl;
#endif

	m_inputData = new InputData();
	//const SolverPara param(true, 10.0f, false, 1.0f, false, 60.0f, false, 1000.0f);
	const SolverPara param(true, gs::weightGeo * gs::weightGeo,
	                       false, gs::weightPhoto * gs::weightPhoto,
	                       true, gs::weightReg * gs::weightReg,
	                       true, gs::weightRot * gs::weightRot);
	m_gnSolver = new GNSolver(m_inputData, param);
	m_gnSolver->initCons(param);

	m_keyPoseVec.resize(MAX_FRAG_NUM);
	m_keyPoseInvVec.resize(MAX_FRAG_NUM);
	m_inputData->m_keyPoses = m_keyPoseVec.data();
	m_inputData->m_dKeyPoses = m_dKeyPoses;
	m_inputData->m_dUpdatedKeyPoses = m_dUpdatedKeyPoses;
	m_inputData->m_dUpdatedKeyPosesInv = m_dUpdatedKeyPosesInv;
	m_inputData->m_dKeyGrayImgs = m_dKeyGrayImgs.first;
	m_inputData->m_dKeyGrayImgsDx = m_dKeyGrayImgsDx.first;
	m_inputData->m_dKeyGrayImgsDy = m_dKeyGrayImgsDy.first;
}

void xDeformation::allocEssentialCUDAMemory()
{
	long long byteUsed = 0;

	m_dKeyGrayImgs.second = m_width * m_height;
	checkCudaErrors(cudaMalloc(&m_dKeyGrayImgs.first, sizeof(float) * m_dKeyGrayImgs.second * MAX_FRAG_NUM));
	byteUsed += sizeof(float) * m_dKeyGrayImgs.second * MAX_FRAG_NUM;

	m_dKeyColorImgs.second = m_width * m_height * 3;
	checkCudaErrors(cudaMalloc(&m_dKeyColorImgs.first, sizeof(uchar) * m_dKeyColorImgs.second * MAX_FRAG_NUM));
	byteUsed += sizeof(uchar) * m_dKeyColorImgs.second * MAX_FRAG_NUM;

	m_dKeyGrayImgsDx.second = m_width * m_height;
	checkCudaErrors(cudaMalloc(&m_dKeyGrayImgsDx.first, sizeof(float) * m_dKeyGrayImgsDx.second * MAX_FRAG_NUM));
	byteUsed += sizeof(uchar) * m_dKeyGrayImgsDx.second * MAX_FRAG_NUM;

	m_dKeyGrayImgsDy.second = m_width * m_height;
	checkCudaErrors(cudaMalloc(&m_dKeyGrayImgsDy.first, sizeof(float) * m_dKeyGrayImgsDy.second * MAX_FRAG_NUM));
	byteUsed += sizeof(uchar) * m_dKeyGrayImgsDy.second * MAX_FRAG_NUM;

	m_dIdxMaps.second = m_width * m_height;
	checkCudaErrors(cudaMalloc(&m_dIdxMaps.first, sizeof(int) * m_dIdxMaps.second * MAX_FRAG_NUM));
	byteUsed += sizeof(int) * m_dIdxMaps.second * MAX_FRAG_NUM;

	checkCudaErrors(cudaMalloc(&m_dIdxMapZBufs.first, m_dIdxMaps.second * sizeof(float) * MAX_FRAG_NUM));
	byteUsed += m_dIdxMaps.second * sizeof(float) * MAX_FRAG_NUM;

	checkCudaErrors(cudaMalloc(&m_dMatchingPointIndices, sizeof(int) * 2 * MAX_CLOSURE_NUM_EACH_FRAG *
		SAMPLED_VERTEX_NUM_EACH_FRAG * MAX_FRAG_NUM));
	byteUsed += sizeof(int) * 2 * MAX_CLOSURE_NUM_EACH_FRAG * SAMPLED_VERTEX_NUM_EACH_FRAG * MAX_FRAG_NUM;

	checkCudaErrors(cudaMalloc(&m_dMatchingFragIndices, sizeof(int) * 2 * MAX_CLOSURE_NUM_EACH_FRAG * MAX_FRAG_NUM));
	byteUsed += sizeof(int) * 2 * MAX_CLOSURE_NUM_EACH_FRAG * MAX_FRAG_NUM;

	checkCudaErrors(cudaMalloc(&m_dKeyPoses, sizeof(float4) * 4 * MAX_FRAG_NUM));
	byteUsed += sizeof(float4) * 4 * MAX_FRAG_NUM;

	checkCudaErrors(cudaMalloc(&m_dUpdatedKeyPosesInv, sizeof(float4) * 4 * MAX_FRAG_NUM));
	byteUsed += sizeof(float4) * 4 * MAX_FRAG_NUM;

	checkCudaErrors(cudaMalloc(&m_dUpdatedKeyPoses, sizeof(float4) * 4 * MAX_FRAG_NUM));
	byteUsed += sizeof(float4) * 4 * MAX_FRAG_NUM;

	std::cout << "preallocated device memory used: " << byteUsed << std::endl;
}

// Using it when do not know the key frame
void xDeformation::addData(const cv::Mat& colorImg,
                           const cv::Mat& fullColorImg,
                           const cv::Mat_<uchar>& grayImg,
                           const cv::cuda::GpuMat& dGrayImg,
                           xMatrix4f pose)
{
	m_grayImgVec.push_back(grayImg.clone());
	m_colorImgVec.push_back(colorImg.clone());
	m_fullColorImgVec.push_back(fullColorImg.clone());

	//innoreal::InnoRealTimer timer;
	//timer.TimeStart();
#if 1
	//m_grayImgDevice.upload(grayImg);
	//float blurScore = CalculateBlurScoreGPU(m_grayImgDevice, m_horizontalBlurImgDevice, m_verticalBlurImgDevice);
	float blurScore = CalculateBlurScoreGPU(dGrayImg, m_dHorizontalBlurImg, m_dVerticalBlurImg);
#else
	float blurScore = CalculateBlurScore(grayImg);
#endif
	//timer.TimeEnd();
	//std::cout << "time blur: " << timer.TimeGap_in_ms() << std::endl;
	//std::cout << "blur score: " << blurScore << std::endl;
	m_blurScoreVec.push_back(blurScore);
	m_poseVec.push_back(pose);

	//std::cout << "blur: " << blurScore << std::endl;
	//std::cout << "pose: " << pose << std::endl;
}

// Using it when know the key frame, no need to calculate the blur score
void xDeformation::addDataWithKeyFrame(const cv::Mat& colorImg,
                                       const cv::Mat& rawDepthImg,
                                       const cv::Mat& grayImg,
                                       xMatrix4f pose)
{
	m_grayImgVec.push_back(grayImg.clone());
    m_depthImgVec.push_back(rawDepthImg.clone());
	m_colorImgVec.push_back(colorImg.clone());
	m_poseVec.push_back(pose);
}

void xDeformation::prepareData(int vertexNum)
{
	std::cout << "=======================" << std::endl;
	std::cout << "vertexNum: " << vertexNum << std::endl;
	std::cout << "=======================" << std::endl;

	int minBlurIdx = 0;
	float minBlurScore = 65536.0f;
	for (int i = 0; i < m_blurScoreVec.size(); ++i)
	{
		if (m_blurScoreVec[i] < minBlurScore)
		{
			minBlurScore = m_blurScoreVec[i];
			minBlurIdx = i;
		}
	}
    //std::cout << "1" << std::endl;

    m_keyFullColorImgVec.push_back(m_fullColorImgVec[minBlurIdx].clone()); 
    //std::cout << "2" << std::endl;

	cv::Mat keyGrayImgFloat;
	m_grayImgVec[minBlurIdx].convertTo(keyGrayImgFloat, CV_32FC1);
	cv::GaussianBlur(keyGrayImgFloat, keyGrayImgFloat, cv::Size(9, 9), 5, 5);
    //std::cout << "3" << std::endl;

	// prepare date for the current fragment
	checkCudaErrors(cudaMemcpy(
		m_dKeyGrayImgs.first + m_fragIdx * m_dKeyGrayImgs.second,
		keyGrayImgFloat.data, m_dKeyGrayImgs.second * sizeof(float), cudaMemcpyHostToDevice));
	checkCudaErrors(cudaMemcpy(
		m_dKeyColorImgs.first + m_fragIdx * m_dKeyColorImgs.second,
		m_colorImgVec[minBlurIdx].data, m_dKeyColorImgs.second * sizeof(uchar), cudaMemcpyHostToDevice));
    //std::cout << "4" << std::endl;

	cv::Mat_<float> dxMat, dyMat;
	cv::sepFilter2D(keyGrayImgFloat, dxMat, dxMat.depth(), m_kxRow, m_kyRow);
	cv::sepFilter2D(keyGrayImgFloat, dyMat, dyMat.depth(), m_kxCol, m_kyCol);

	checkCudaErrors(cudaMemcpy(
		m_dKeyGrayImgsDx.first + m_fragIdx * m_dKeyGrayImgsDx.second,
		dxMat.data, m_width * m_height * sizeof(float), cudaMemcpyHostToDevice));
	checkCudaErrors(cudaMemcpy(
		m_dKeyGrayImgsDy.first + m_fragIdx * m_dKeyGrayImgsDy.second,
		dyMat.data, m_width * m_height * sizeof(float), cudaMemcpyHostToDevice));

	m_keyPoseVec[m_fragIdx] = m_poseVec[minBlurIdx];
	m_keyPoseInvVec[m_fragIdx] = m_poseVec[minBlurIdx].inverse();
	//m_keyPoseVec.push_back(m_poseVec[minBlurInd]);
	//m_keyPoseInvVec.push_back(m_poseVec[minBlurInd].inverse());
	checkCudaErrors(cudaMemcpy(
		m_dKeyPoses + m_fragIdx * 4,
		m_keyPoseVec[m_fragIdx].data(), sizeof(float4) * 4, cudaMemcpyHostToDevice));
	checkCudaErrors(cudaMemcpy(
		m_dUpdatedKeyPoses + m_fragIdx * 4,
		m_keyPoseVec[m_fragIdx].data(), sizeof(float4) * 4, cudaMemcpyHostToDevice));
	checkCudaErrors(cudaMemcpy(
		m_dUpdatedKeyPosesInv + m_fragIdx * 4,
		m_keyPoseInvVec[m_fragIdx].data(), sizeof(float4) * 4, cudaMemcpyHostToDevice));

#if 0
	int vertexNumFrag = m_vertexStrideVec[m_fragInd + 1] - m_vertexStrideVec[m_fragInd];
	VertexFilter(m_vboDevice + m_vertexStrideVec[m_fragInd], vertexNumFrag, m_keyPosesDevice + m_fragInd * 4,
		Intrinsics::getInstance().fx(), Intrinsics::getInstance().fy(), Intrinsics::getInstance().cx(), Intrinsics::getInstance().cy());
#endif

#if 0
	std::cout << "minBlurScore: " << minBlurScore << std::endl;
	if (minBlurScore < 0.315)
	{
		m_isFragValid[fragInd] = false;
		goto invalid_fragment;
	}
#endif

	m_poseGraph.push_back(std::vector<int>());
	m_poseGraphInv.push_back(std::vector<int>());
	updatePoseGraph();

	m_inputData->prepareData(m_dVboCuda, vertexNum, m_fragIdx);
	m_gnSolver->initVars();
}

void xDeformation::prepareDataWithKeyFrame(int vertexNum, int keyFrameIdxEachFrag)
{
	std::cout << "=======================" << std::endl;
	std::cout << "vertexNum: " << vertexNum << std::endl;
	std::cout << "=======================" << std::endl;

	cv::Mat keyGrayImgFloat;
	m_grayImgVec[keyFrameIdxEachFrag].convertTo(keyGrayImgFloat, CV_32FC1);
	cv::GaussianBlur(keyGrayImgFloat, keyGrayImgFloat, cv::Size(9, 9), 5, 5);

    m_keyDepthImgVec.push_back(m_depthImgVec[keyFrameIdxEachFrag]);

	// prepare date for the current fragment
	checkCudaErrors(cudaMemcpy(
		m_dKeyGrayImgs.first + m_fragIdx * m_dKeyGrayImgs.second,
		keyGrayImgFloat.data, m_dKeyGrayImgs.second * sizeof(float), cudaMemcpyHostToDevice));
	checkCudaErrors(cudaMemcpy(
		m_dKeyColorImgs.first + m_fragIdx * m_dKeyColorImgs.second,
		m_colorImgVec[keyFrameIdxEachFrag].data, m_dKeyColorImgs.second * sizeof(uchar), cudaMemcpyHostToDevice));

	cv::Mat_<float> dxMat, dyMat;
	cv::sepFilter2D(keyGrayImgFloat, dxMat, dxMat.depth(), m_kxRow, m_kyRow);
	cv::sepFilter2D(keyGrayImgFloat, dyMat, dyMat.depth(), m_kxCol, m_kyCol);

	checkCudaErrors(cudaMemcpy(
		m_dKeyGrayImgsDx.first + m_fragIdx * m_dKeyGrayImgsDx.second,
		dxMat.data, m_width * m_height * sizeof(float), cudaMemcpyHostToDevice));
	checkCudaErrors(cudaMemcpy(
		m_dKeyGrayImgsDy.first + m_fragIdx * m_dKeyGrayImgsDy.second,
		dyMat.data, m_width * m_height * sizeof(float), cudaMemcpyHostToDevice));

	m_keyPoseVec[m_fragIdx] = m_poseVec[keyFrameIdxEachFrag];
	m_keyPoseInvVec[m_fragIdx] = m_poseVec[keyFrameIdxEachFrag].inverse();
	//m_keyPoseVec.push_back(m_poseVec[minBlurInd]);
	//m_keyPoseInvVec.push_back(m_poseVec[minBlurInd].inverse());
	checkCudaErrors(cudaMemcpy(
		m_dKeyPoses + m_fragIdx * 4,
		m_keyPoseVec[m_fragIdx].data(), sizeof(float4) * 4, cudaMemcpyHostToDevice));
	checkCudaErrors(cudaMemcpy(
		m_dUpdatedKeyPoses + m_fragIdx * 4,
		m_keyPoseVec[m_fragIdx].data(), sizeof(float4) * 4, cudaMemcpyHostToDevice));
	checkCudaErrors(cudaMemcpy(
		m_dUpdatedKeyPosesInv + m_fragIdx * 4,
		m_keyPoseInvVec[m_fragIdx].data(), sizeof(float4) * 4, cudaMemcpyHostToDevice));

	m_poseGraph.push_back(std::vector<int>());
	m_poseGraphInv.push_back(std::vector<int>());
	updatePoseGraph();

	m_inputData->prepareData(m_dVboCuda, vertexNum, m_fragIdx);
	m_gnSolver->initVars();
}

void xDeformation::deform(xMatrix4f* latestPose, VBOType* vboDevice, int vertexNum, int keyFrameIdxEachFrag)
{
#if USE_STRUCTURE_SENSOR 
	prepareDataWithKeyFrame(vertexNum, keyFrameIdxEachFrag);
#endif
#if USE_XTION
	prepareData(vertexNum);
#endif
#if USE_RENDERED_DATA 
    prepareData(vertexNum);
#endif

	// do optimization
	std::cout << "fragInd: " << m_fragIdx << std::endl;
	std::cout << "loopClosureNum: " << m_loopClosureNum << std::endl;
	int iterNum = 6;
	if (m_loopClosureNum > 0) // && m_fragInd > 1)
	{
		innoreal::InnoRealTimer timer;
		timer.TimeStart();
#if 1
		doOptimize(iterNum);
#endif
		timer.TimeEnd();
		std::cout << "optimize time: " << timer.TimeGap_in_ms() << std::endl;

#if 1
		xMatrix4f& keyPose = m_keyPoseVec[m_fragIdx];
		xMatrix4f updatedKeyPose;
		std::cout << "pose before opt: " << std::endl;
		latestPose->print();
		checkCudaErrors(cudaMemcpy(
			updatedKeyPose.data(),
			m_dUpdatedKeyPoses + m_fragIdx * 4, sizeof(float4) * 4, cudaMemcpyDeviceToHost));
		*latestPose = updatedKeyPose * keyPose.inverse() * (*latestPose);
		std::cout << "pose after opt: " << std::endl;
		latestPose->print();
#endif
	}
	//if (m_fragInd == 3)
	//std::exit(0);

invalid_fragment:
	m_grayImgVec.clear();
    m_depthImgVec.clear();
	m_colorImgVec.clear();
	m_fullColorImgVec.clear();
	m_blurScoreVec.clear();
	m_poseVec.clear();
}

static bool AngleVecCompare(const std::pair<float, int>& a, const std::pair<float, int>& b)
{
	return a.first > b.first;
}

void xDeformation::updatePoseGraph()
{
	int latestPoseIdx = m_fragIdx;
	//int latestPoseIdx = m_keyPoseVec.size() - 1;
	xMatrix4f& latestPoseMat = m_keyPoseVec[latestPoseIdx];
	float4 latestCamOrient = m_keyPoseVec[latestPoseIdx].col(2), camOrient;
	xMatrix4f ralaTrans;

	std::vector<std::pair<float, int>> angleVec;

	for (int i = latestPoseIdx - 1; i >= 0; --i)
	{
		camOrient = m_keyPoseVec[i].col(2);
		if (m_isFragValid[i] > 0 && dot(camOrient, latestCamOrient) > -0.5)
		{
			angleVec.push_back(std::make_pair(dot(camOrient, latestCamOrient), i));
		}
	}
	std::sort(angleVec.begin(), angleVec.end(), AngleVecCompare);
#if 0
	for (int i = 0; i < angleVec.size(); ++i)
	{
		std::cout << angleVec[i].second << std::endl;
	}
#endif
	for (int i = 0; i < MIN(angleVec.size(), MAX_CLOSURE_NUM_EACH_FRAG); ++i)
	{
		m_poseGraph[angleVec[i].second].push_back(latestPoseIdx);
		m_poseGraphInv[latestPoseIdx].push_back(angleVec[i].second);
		++m_loopClosureNum;
	}
	std::cout << "loop closure num: " << m_loopClosureNum << std::endl;
}

void xDeformation::findMatchingKNN()
{
	FragDeformableMeshData& sourceMesh = m_inputData->m_source;
	MeshData& deformedMesh = m_inputData->m_deformed;

	int* sampledVertexIndicesDeviceSrcFrag;
	int* matchingPointsFrag;
	int vertexNumSrc, sampledVertexNumSrc, vertexNumTarget, vertexIndBaseTarget;

	float4* sampledUpdatedVertexPosesSrc;
	checkCudaErrors(cudaMalloc(&sampledUpdatedVertexPosesSrc, sizeof(float4) * SAMPLED_VERTEX_NUM_EACH_FRAG));
	int* knnIndex;
	float* knnWeight;
	checkCudaErrors(cudaMalloc(&knnIndex, sizeof(int) * SAMPLED_VERTEX_NUM_EACH_FRAG));
	checkCudaErrors(cudaMalloc(&knnWeight, sizeof(float) * SAMPLED_VERTEX_NUM_EACH_FRAG));

	int srcFragInd;
	int matchingVertexNum;
	checkCudaErrors(cudaDeviceSynchronize());
	checkCudaErrors(cudaGetLastError());
	m_matchingPointNum = m_matchingPointsNumDescriptor;
	for (int targetFragInd = 0; targetFragInd < m_poseGraph.size(); ++targetFragInd)
	{
		vertexNumTarget = sourceMesh.m_vertexStrideVec[targetFragInd + 1] - sourceMesh.m_vertexStrideVec
			[targetFragInd];
		vertexIndBaseTarget = sourceMesh.m_vertexStrideVec[targetFragInd];

		NearestPoint nearestPoint;
		nearestPoint.InitKDTree(
			RAW_PTR(deformedMesh.m_dVertexVec) + sourceMesh.m_vertexStrideVec[targetFragInd],
			vertexNumTarget);
		checkCudaErrors(cudaDeviceSynchronize());
		checkCudaErrors(cudaGetLastError());

		for (int ind = 0; ind < m_poseGraph[targetFragInd].size(); ++ind)
		{
			srcFragInd = m_poseGraph[targetFragInd][ind];
			if (m_isFragValid[srcFragInd] <= 0 || m_isFragValid[targetFragInd] <= 0)
			{
				continue;
			}
#if 0
			std::cout << "src: " << srcFragInd << std::endl;
			std::cout << "target: " << targetFragInd << std::endl;
			std::cout << "vertexIdBaseTarget: " << vertexIndBaseTarget << std::endl;
#endif
			sampledVertexNumSrc = SAMPLED_VERTEX_NUM_EACH_FRAG;
			matchingPointsFrag = m_dMatchingPointIndices + 2 * m_matchingPointNum;
			m_matchingPointNum += sampledVertexNumSrc;

			CompressSampledVertex(sampledUpdatedVertexPosesSrc, RAW_PTR(deformedMesh.m_dVertexVec),
			                      RAW_PTR(sourceMesh.m_dSampledVertexIdxVec) + SAMPLED_VERTEX_NUM_EACH_FRAG *
			                      srcFragInd, sampledVertexNumSrc);
			checkCudaErrors(cudaDeviceSynchronize());
			checkCudaErrors(cudaGetLastError());

			nearestPoint.GetKnnResult(sampledUpdatedVertexPosesSrc, sampledVertexNumSrc, 1,
			                          knnIndex,
			                          knnWeight);
			checkCudaErrors(cudaDeviceSynchronize());
			checkCudaErrors(cudaGetLastError());

			AddToMatchingPoints(matchingPointsFrag,
			                    RAW_PTR(sourceMesh.m_dSampledVertexIdxVec) + SAMPLED_VERTEX_NUM_EACH_FRAG *
			                    srcFragInd,
			                    knnIndex, vertexIndBaseTarget, sampledVertexNumSrc);
		}
	}
	m_matchingPointsNumNearest = m_matchingPointNum - m_matchingPointsNumDescriptor;
	checkCudaErrors(cudaFree(sampledUpdatedVertexPosesSrc));
	checkCudaErrors(cudaFree(knnIndex));
	checkCudaErrors(cudaFree(knnWeight));
}

void xDeformation::findMatchingPerspective()
{
	FragDeformableMeshData& sourceMesh = m_inputData->m_source;
	MeshData& deformedMesh = m_inputData->m_deformed;

	int vertexNum = sourceMesh.m_vertexStrideVec[m_fragIdx + 1];
	m_matchingPointNum = m_matchingPointsNumDescriptor;

	std::vector<int> matchingFragsIndicesVec;
	matchingFragsIndicesVec.reserve(100);
	int srcFragInd;
	for (int targetFragInd = 0; targetFragInd < m_poseGraph.size(); ++targetFragInd)
	{
		for (int ind = 0; ind < m_poseGraph[targetFragInd].size(); ++ind)
		{
			srcFragInd = m_poseGraph[targetFragInd][ind];
			//std::cout << srcFragInd << " : " << targetFragInd << std::endl;
			matchingFragsIndicesVec.push_back(srcFragInd);
			matchingFragsIndicesVec.push_back(targetFragInd);
		}
	}
	assert(m_loopClosureNum == (matchingFragsIndicesVec.size() / 2));
	checkCudaErrors(cudaMemcpy(m_dMatchingFragIndices, matchingFragsIndicesVec.data(),
		matchingFragsIndicesVec.size() * sizeof(int), cudaMemcpyHostToDevice));

	UpdateIndMapsPerspective(m_dIdxMaps.first,
	                         m_dIdxMapZBufs.first,
	                         m_width, m_height, m_fragIdx + 1, vertexNum,
	                         Intrinsics::getInstance().fx(), Intrinsics::getInstance().fy(),
	                         Intrinsics::getInstance().cx(), Intrinsics::getInstance().cy(),
	                         RAW_PTR(deformedMesh.m_dVertexVec),
	                         RAW_PTR(deformedMesh.m_dNormalVec),
	                         m_dUpdatedKeyPosesInv);

	m_matchingPointsNumNearest = m_loopClosureNum * SAMPLED_VERTEX_NUM_EACH_FRAG;
	FindMatchingPointsPerspective(
		m_dMatchingPointIndices + 2 * m_matchingPointNum,
		m_dMatchingFragIndices,
		RAW_PTR(deformedMesh.m_dVertexVec),
		m_dIdxMaps,
		m_dUpdatedKeyPosesInv,
		RAW_PTR(sourceMesh.m_dSampledVertexIdxVec),
		m_width, m_height, Intrinsics::getInstance().fx(), Intrinsics::getInstance().fy(), Intrinsics::getInstance().cx(),
		Intrinsics::getInstance().cy(),
		m_matchingPointsNumNearest);

	m_matchingPointNum += m_matchingPointsNumNearest;
}

void xDeformation::doOptimize(int iterNum)
{
	//int vertexNum = m_inputData->m_source.m_vertexStrideVec[m_fragIdx + 1];
	//int nodeNum = NODE_NUM_EACH_FRAG * (m_fragIdx + 1);
	for (int iter = 0; iter < iterNum; ++iter)
	{
		findMatchingPoints();
		FilterInvalidMatchingPoints(
			m_dMatchingPointIndices,
			m_matchingPointsNumDescriptor,
			m_matchingPointNum,
			RAW_PTR(m_inputData->m_deformed.m_dVertexVec),
			RAW_PTR(m_inputData->m_deformed.m_dNormalVec),
			iter);
		m_inputData->m_dMatchingPointIndices = m_dMatchingPointIndices;
		m_inputData->m_matchingPointNum = m_matchingPointNum;
		m_inputData->getIijSet(m_dMatchingPointIndices, m_matchingPointNum);

		m_gnSolver->initJtj();
		m_gnSolver->next(iter);
	}
	m_gnSolver->updateVboVec(m_dVboCuda);

	return;
}

void xDeformation::savePly(const char* fileDir, int fragIdx)
{
	FragDeformableMeshData& sourceMesh = m_inputData->m_source;
	int vertexNum;
	if (fragIdx == -1)
	{
		vertexNum = sourceMesh.m_vertexStrideVec[sourceMesh.m_fragNum];
	}
	else
	{
		vertexNum = sourceMesh.m_vertexStrideVec[fragIdx + 1] - sourceMesh.m_vertexStrideVec[fragIdx];
	}
	std::cout << "save ply\nvertexNum: " << vertexNum << std::endl;
	std::vector<VBOType> vboCudaVec(vertexNum);

	std::ofstream fs;
	fs.open(fileDir);
	if (fragIdx == -1)
	{
		checkCudaErrors(cudaMemcpy(vboCudaVec.data(),
			m_dVboCuda,
			vboCudaVec.size() * sizeof(VBOType), cudaMemcpyDeviceToHost));
	}
	else
	{
		checkCudaErrors(cudaMemcpy(vboCudaVec.data(),
			m_dVboCuda + sourceMesh.m_vertexStrideVec[fragIdx],
			vboCudaVec.size() * sizeof(VBOType), cudaMemcpyDeviceToHost));
	}

	int validVertexNumFrag = 0;
	for (unsigned int i = 0; i < vertexNum; i++)
	{
		VBOType& posColorNor = vboCudaVec[i];
		if (posColorNor.colorTime.y >= 0)
		{
			++validVertexNumFrag;
		}
	}

	fs << "ply";
	fs << "\nformat " << "ascii" << " 1.0";
	fs << "\nelement vertex " << validVertexNumFrag;
	fs << "\nproperty float x"
		"\nproperty float y"
		"\nproperty float z";
	fs << "\nproperty uchar red"
		"\nproperty uchar green"
		"\nproperty uchar blue";
	fs << "\nproperty float nx"
		"\nproperty float ny"
		"\nproperty float nz";
	fs << "\nend_header\n";

	int cnt = 0;
	int randNum_0 = rand() % 3;
	int randNum_1 = rand() % 250 - 50;
	for (unsigned int i = 0; i < validVertexNumFrag; i++)
	{
		VBOType& posColorNor = vboCudaVec[i];

		if (posColorNor.colorTime.y >= 0)
		{
			unsigned char b, g, r;
			b = int(posColorNor.colorTime.x) >> 16 & 0xFF;
			g = int(posColorNor.colorTime.x) >> 8 & 0xFF;
			r = int(posColorNor.colorTime.x) & 0xFF;
			fs << posColorNor.posConf.x << " " << posColorNor.posConf.y << " " << posColorNor.posConf.z << " "
				<< (int)r << " " << (int)g << " " << (int)b << " "
				<< -posColorNor.normalRad.x << " " << -posColorNor.normalRad.y << " " << -posColorNor.normalRad.z
				<< std::endl;
		}
	}

	fs.close();
}

void xDeformation::saveModel()
{
	std::cout << "save model" << std::endl;

	FragDeformableMeshData& sourceMesh = m_inputData->m_source;

	char fileDir[256];
	sprintf(fileDir, "D:\\xjm\\result\\before_opt\\whole_model.ply");
	savePly(fileDir, -1);
	for (int i = 0; i < sourceMesh.m_fragNum; ++i)
	{
		sprintf(fileDir, "D:\\xjm\\result\\before_opt\\%06d.ply", i);
		savePly(fileDir, i);
	}

	int width = Resolution::getInstance().width();
	int height = Resolution::getInstance().height();
    cv::Mat keyColorImg(height, width, CV_8UC3);
    //cv::Mat keyGrayImg(height, width, CV_8UC1);
	//cv::Mat keyColorImgResized(height, width, CV_8UC3);
	std::vector<int> pngCompressionParams;
	pngCompressionParams.push_back(CV_IMWRITE_PNG_COMPRESSION);
	pngCompressionParams.push_back(0);
	std::ofstream fs1, fs2;
	fs1.open("D:\\xjm\\result\\before_opt\\camera_pose.txt", std::ofstream::binary);
	fs2.open("D:\\xjm\\result\\before_opt\\camera_pose_original.txt", std::ofstream::binary);

	float4 camPose[4], oriCamPose[4], invCamPose[4];
	for (int fragIdx = 0; fragIdx < sourceMesh.m_fragNum; ++fragIdx)
	{
		checkCudaErrors(cudaMemcpy(camPose,
			m_inputData->m_dUpdatedKeyPoses + 4 * fragIdx,
			4 * sizeof(float4), cudaMemcpyDeviceToHost));
        checkCudaErrors(cudaMemcpy(oriCamPose,
            m_inputData->m_dKeyPoses + 4 * fragIdx,
            4 * sizeof(float4), cudaMemcpyDeviceToHost));
#if 0
		checkCudaErrors(cudaMemcpy(invCamPose,
			m_inputData->m_dUpdatedKeyPosesInv + 4 * fragIdx,
			4 * sizeof(float4), cudaMemcpyDeviceToHost));
#endif
		std::cout << "camera pose: " <<
			camPose[0].x << " " << camPose[0].y << " " << camPose[0].z << " " << camPose[0].w <<
			camPose[1].x << " " << camPose[1].y << " " << camPose[1].z << " " << camPose[1].w <<
			camPose[2].x << " " << camPose[2].y << " " << camPose[2].z << " " << camPose[2].w <<
			camPose[3].x << " " << camPose[3].y << " " << camPose[3].z << " " << camPose[3].w << std::endl;
		fs1.write((char *)camPose, 4 * sizeof(float4));
		fs2.write((char *)oriCamPose, 4 * sizeof(float4));

#if 0
        sprintf(fileDir, "D:\\xjm\\result\\before_opt\\%06d_key_depth.png", fragIdx);
        cv::imwrite(fileDir, m_keyDepthImgVec[fragIdx], pngCompressionParams);
#endif
#if 0
        checkCudaErrors(cudaMemcpy(keyColorImg.data,
            m_dKeyColorImgs.first + fragIdx * m_dKeyColorImgs.second,
            keyColorImg.rows * keyColorImg.cols * 3,
            cudaMemcpyDeviceToHost));
        sprintf(fileDir, "D:\\xjm\\result\\before_opt\\%06d_key_frame.png", fragIdx);
        cv::imwrite(fileDir, keyColorImg, pngCompressionParams);
#endif
       
#if 1
        sprintf(fileDir, "D:\\xjm\\result\\before_opt\\%06d_key_frame.png", fragIdx);
        cv::imwrite(fileDir, m_keyFullColorImgVec[fragIdx], pngCompressionParams);
#endif

		std::cout << "Frag " << fragIdx << " has been saved" << std::endl;
	}
	fs1.close();
	fs2.close();
	exit(0);
}

int xDeformation::getSrcVertexNum()
{
	return m_inputData->getSrcVertexNum();
}

int xDeformation::getSrcNodeNum()
{
	return m_inputData->getSrcNodeNum();
}

int xDeformation::getFragNum()
{
	return m_fragIdx + 1;
}

void xDeformation::getVertexStrideVe(std::vector<int>& vertexStrideVec)
{
	vertexStrideVec = m_inputData->m_source.m_vertexStrideVec;
}

void xDeformation::getDeformedVertices(std::vector<float4>& deformedVertexVec)
{
	deformedVertexVec.resize(m_inputData->m_deformed.m_vertexNum);

	checkCudaErrors(cudaMemcpy(deformedVertexVec.data(), RAW_PTR(m_inputData->m_deformed.m_dVertexVec),
		deformedVertexVec.size() * sizeof(float4), cudaMemcpyDeviceToHost));
}

void xDeformation::getDeformedNormals(std::vector<float4>& deformedVertexVec)
{
	deformedVertexVec.resize(this->m_inputData->m_deformed.m_vertexNum);

	checkCudaErrors(cudaMemcpy(deformedVertexVec.data(), RAW_PTR(m_inputData->m_deformed.m_dNormalVec),
		deformedVertexVec.size() * sizeof(float4), cudaMemcpyDeviceToHost));
}

void xDeformation::getMatchingPointIndices(std::vector<int>& matchingPointIdxVec)
{
	matchingPointIdxVec.resize(m_inputData->m_matchingPointNum * 2);

	checkCudaErrors(cudaMemcpy(matchingPointIdxVec.data(), RAW_PTR(m_inputData->m_dMatchingPointIndices),
		matchingPointIdxVec.size() * sizeof(int), cudaMemcpyDeviceToHost));
}

