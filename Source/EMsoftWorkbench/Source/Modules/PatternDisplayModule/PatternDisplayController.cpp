/* ============================================================================
 * Copyright (c) 2009-2017 BlueQuartz Software, LLC
 *
 * Redistribution and use in source and binary forms, with or without modification,
 * are permitted provided that the following conditions are met:
 *
 * Redistributions of source code must retain the above copyright notice, this
 * list of conditions and the following disclaimer.
 *
 * Redistributions in binary form must reproduce the above copyright notice, this
 * list of conditions and the following disclaimer in the documentation and/or
 * other materials provided with the distribution.
 *
 * Neither the name of BlueQuartz Software, the US Air Force, nor the names of its
 * contributors may be used to endorse or promote products derived from this software
 * without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
 * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 * SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
 * CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
 * OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE
 * USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 *
 * The code contained herein was partially funded by the followig contracts:
 *    United States Air Force Prime Contract FA8650-07-D-5800
 *    United States Air Force Prime Contract FA8650-10-D-5210
 *    United States Prime Contract Navy N00173-07-C-2068
 *
 * ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~ */

#include "PatternDisplayController.h"

#include <initializer_list>

#include <QtConcurrent>
#include <QtCore/QFileInfo>

#include "Common/ImageGenerator.h"
#include "Common/PatternTools.h"
#include "Common/ProjectionConversions.hpp"

#include "Modules/PatternDisplayModule/PatternListModel.h"

// -----------------------------------------------------------------------------
//
// -----------------------------------------------------------------------------
PatternDisplayController::PatternDisplayController(QObject* parent)
: QObject(parent)
, m_Observer(nullptr)
, m_NumOfFinishedPatternsLock(1)
, m_CurrentOrderLock(1)
, m_MasterLPNHImageGenLock(1)
, m_MasterLPSHImageGenLock(1)
, m_MasterCircleImageGenLock(1)
, m_MasterStereoImageGenLock(1)
, m_MCSquareImageGenLock(1)
, m_MCCircleImageGenLock(1)
, m_MCStereoImageGenLock(1)
{
  // Connection to allow the pattern list to redraw itself
  PatternListModel* model = PatternListModel::Instance();
  connect(this, SIGNAL(rowDataChanged(const QModelIndex&, const QModelIndex&)), model, SIGNAL(dataChanged(const QModelIndex&, const QModelIndex&)), Qt::QueuedConnection);
}

// -----------------------------------------------------------------------------
//
// -----------------------------------------------------------------------------
PatternDisplayController::~PatternDisplayController() = default;

// -----------------------------------------------------------------------------
//
// -----------------------------------------------------------------------------
void PatternDisplayController::setMasterFilePath(const QString& masterFilePath)
{
  m_MasterFilePath = masterFilePath;

  QFileInfo fi(masterFilePath);
  emit stdOutputMessageGenerated("Full Path: " + masterFilePath);
  emit stdOutputMessageGenerated("Path: " + fi.path());
  emit stdOutputMessageGenerated("Data File: " + fi.fileName());
  emit stdOutputMessageGenerated("Suffix: " + fi.completeSuffix() + "\n");

  MasterPatternFileReader reader(masterFilePath, m_Observer);
  m_MP_Data = reader.readMasterPatternData();

  if(m_MP_Data.ekevs.empty())
  {
    return;
  }
  emit minMaxEnergyLevelsChanged(m_MP_Data.ekevs);

  createMasterPatternImageGenerators();
  createMonteCarloImageGenerators();
  checkImageGenerationCompletion();
}

// -----------------------------------------------------------------------------
//
// -----------------------------------------------------------------------------
void PatternDisplayController::createMasterPatternImageGenerators()
{
  m_MasterLPNHImageGenerators.clear();
  m_MasterLPSHImageGenerators.clear();
  m_MasterCircleImageGenerators.clear();
  m_MasterStereoImageGenerators.clear();

  hsize_t mp_zDim = m_MP_Data.mLPNH_dims[1];

  size_t currentCount = 1;
  size_t totalItems = 4;

  // Read Master Pattern lambert square projection data
  emit stdOutputMessageGenerated(tr("File generated by program '%1'").arg(m_MP_Data.mpProgramName));
  emit stdOutputMessageGenerated(tr("Version Identifier: %1").arg(m_MP_Data.mpVersionId));
  emit stdOutputMessageGenerated(tr("Number Of Energy Bins: %1\n").arg(QString::number(m_MP_Data.numMPEnergyBins)));

  QString mpDimStr = "";
  for(int i = 0; i < m_MP_Data.mLPNH_dims.size(); i++)
  {
    mpDimStr.append(QString::number(m_MP_Data.mLPNH_dims[i]));
    if(i < m_MP_Data.mLPNH_dims.size() - 1)
    {
      mpDimStr.append(" x ");
    }
  }

  emit stdOutputMessageGenerated(tr("Size of mLPNH data array: %1").arg(mpDimStr));

  // Create the master pattern northern hemisphere generators
  m_MasterLPNHImageGenerators.resize(mp_zDim);
  emit stdOutputMessageGenerated(tr("Reading Master Pattern data sets (%1/%2)...").arg(currentCount).arg(totalItems));
  createImageGeneratorTasks<float>(m_MP_Data.masterLPNHData, m_MP_Data.mLPNH_dims[3], m_MP_Data.mLPNH_dims[2], mp_zDim, m_MasterLPNHImageGenerators, m_MasterLPNHImageGenLock);
  currentCount++;

  // Create the master pattern southern hemisphere generators
  m_MasterLPSHImageGenerators.resize(mp_zDim);
  emit stdOutputMessageGenerated(tr("Reading Master Pattern data sets (%1/%2)...").arg(currentCount).arg(totalItems));
  createImageGeneratorTasks<float>(m_MP_Data.masterLPSHData, m_MP_Data.mLPSH_dims[3], m_MP_Data.mLPSH_dims[2], mp_zDim, m_MasterLPSHImageGenerators, m_MasterLPSHImageGenLock);
  currentCount++;

  // Convert to Master Pattern Lambert Circle projection data and create generators
  m_MasterCircleImageGenerators.resize(mp_zDim);
  emit stdOutputMessageGenerated(tr("Reading Master Pattern data sets (%1/%2)...").arg(currentCount).arg(totalItems));
  createProjectionConversionTasks<float, float>(m_MP_Data.masterLPNHData, m_MP_Data.mLPNH_dims[3], m_MP_Data.mLPNH_dims[2], mp_zDim, m_MP_Data.mLPNH_dims[3],
                                                ModifiedLambertProjection::ProjectionType::Circular, ModifiedLambertProjection::Square::NorthSquare, m_MasterCircleImageGenerators,
                                                m_MasterCircleImageGenLock);
  currentCount++;

  // Create the master pattern stereographic projection generators
  m_MasterStereoImageGenerators.resize(mp_zDim);
  emit stdOutputMessageGenerated(tr("Reading Master Pattern data sets (%1/%2)...").arg(currentCount).arg(totalItems));
  createImageGeneratorTasks<float>(m_MP_Data.masterSPNHData, m_MP_Data.masterSPNH_dims[2], m_MP_Data.masterSPNH_dims[1], mp_zDim, m_MasterStereoImageGenerators, m_MasterStereoImageGenLock);

  emit stdOutputMessageGenerated(tr("Reading Master Pattern data sets complete!\n"));
}

// -----------------------------------------------------------------------------
//
// -----------------------------------------------------------------------------
void PatternDisplayController::createMonteCarloImageGenerators()
{
  m_MCSquareImageGenerators.clear();
  m_MCCircleImageGenerators.clear();
  m_MCStereoImageGenerators.clear();

  size_t currentCount = 1;
  size_t totalItems = 3;
  size_t mc_zDim = m_MP_Data.monteCarlo_dims[2];

  // Read Monte Carlo lambert square projection data
  emit stdOutputMessageGenerated(tr("File generated by program '%1'").arg(m_MP_Data.mcProgramName));
  emit stdOutputMessageGenerated(tr("Version Identifier: %1").arg(m_MP_Data.mcVersionId));

  emit stdOutputMessageGenerated(tr("Dehyperslabbing Monte Carlo square data..."));
  std::vector<int32_t> monteCarloSquare_data = deHyperSlabData<int32_t>(m_MP_Data.monteCarloSquareData, m_MP_Data.monteCarlo_dims[0], m_MP_Data.monteCarlo_dims[1], m_MP_Data.monteCarlo_dims[2]);

  // Generate Monte Carlo square projection data
  m_MCSquareImageGenerators.resize(mc_zDim);
  emit stdOutputMessageGenerated(tr("Reading Monte Carlo data sets (%1/%2)...").arg(currentCount).arg(totalItems));
  createImageGeneratorTasks<int32_t>(monteCarloSquare_data, m_MP_Data.monteCarlo_dims[0], m_MP_Data.monteCarlo_dims[1], mc_zDim, m_MCSquareImageGenerators, m_MCSquareImageGenLock);
  currentCount++;

  // Generate Monte Carlo circular projection data
  m_MCCircleImageGenerators.resize(mc_zDim);
  emit stdOutputMessageGenerated(tr("Reading Monte Carlo data sets (%1/%2)...").arg(currentCount).arg(totalItems));
  createProjectionConversionTasks<int32_t, float>(monteCarloSquare_data, m_MP_Data.monteCarlo_dims[0], m_MP_Data.monteCarlo_dims[1], mc_zDim, m_MP_Data.monteCarlo_dims[0],
                                                  ModifiedLambertProjection::ProjectionType::Circular, ModifiedLambertProjection::Square::NorthSquare, m_MCCircleImageGenerators,
                                                  m_MCCircleImageGenLock, false, true);
  currentCount++;

  // Generate Monte Carlo stereographic projection data
  m_MCStereoImageGenerators.resize(mc_zDim);
  emit stdOutputMessageGenerated(tr("Reading Monte Carlo data sets (%1/%2)...").arg(currentCount).arg(totalItems));
  createProjectionConversionTasks<int32_t, float>(monteCarloSquare_data, m_MP_Data.monteCarlo_dims[0], m_MP_Data.monteCarlo_dims[1], mc_zDim, m_MP_Data.monteCarlo_dims[0],
                                                  ModifiedLambertProjection::ProjectionType::Stereographic, ModifiedLambertProjection::Square::NorthSquare, m_MCStereoImageGenerators,
                                                  m_MCStereoImageGenLock, false, true);

  QString mcDimStr = "";
  for(int i = 0; i < m_MP_Data.monteCarlo_dims.size(); i++)
  {
    mcDimStr.append(QString::number(m_MP_Data.monteCarlo_dims[i]));
    if(i < m_MP_Data.monteCarlo_dims.size() - 1)
    {
      mcDimStr.append(" x ");
    }
  }

  emit stdOutputMessageGenerated(tr("Reading Monte Carlo data sets complete!\n"));
}

// -----------------------------------------------------------------------------
//
// -----------------------------------------------------------------------------
void PatternDisplayController::checkImageGenerationCompletion()
{
  if(QThreadPool::globalInstance()->activeThreadCount() > 0)
  {
    QTimer::singleShot(100, this, SLOT(checkImageGenerationCompletion()));
  }
  else
  {
    // Set the default range of the images to be displayed (masterLPNH is always displayed first by default)
    emit imageRangeChanged(1, m_MasterLPNHImageGenerators.size());

    emit mpmcGenerationFinished();
  }
}

// -----------------------------------------------------------------------------
//
// -----------------------------------------------------------------------------
void PatternDisplayController::generatePatternImagesUsingThread(SimulatedPatternDisplayWidget::PatternDisplayData patternData, PatternDisplayController::DetectorData detectorData)
{
  PatternListModel* model = PatternListModel::Instance();

  while(!m_CurrentOrder.empty())
  {
    if(m_Cancel)
    {
      return;
    }

    // Load the next image
    if(m_CurrentOrderLock.tryAcquire())
    {
      int index;
      if(!m_PriorityOrder.empty())
      {
        // An index in this thread has been given priority
        index = m_PriorityOrder.front();
        m_PriorityOrder.pop_front();
        m_CurrentOrder.removeAll(index);
      }
      else
      {
        index = m_CurrentOrder.front();
        m_CurrentOrder.pop_front();
      }
      m_CurrentOrderLock.release();

      QModelIndex modelIndex = model->index(index, PatternListItem::DefaultColumn);
      model->setPatternStatus(index, PatternListItem::PatternStatus::Loading);
      emit rowDataChanged(modelIndex, modelIndex);

      // Build up the iParValues object
      PatternTools::IParValues iParValues;
      iParValues.numsx = m_MP_Data.numsx;
      iParValues.numset = m_MP_Data.numset;
      iParValues.incidentBeamVoltage = m_MP_Data.incidentBeamVoltage;
      iParValues.minEnergy = m_MP_Data.minEnergy;
      iParValues.energyBinSize = m_MP_Data.energyBinSize;
      iParValues.npx = m_MP_Data.npx;
      iParValues.numOfPixelsX = detectorData.numOfPixelsX;
      iParValues.numOfPixelsY = detectorData.numOfPixelsY;
      iParValues.detectorBinningValue = patternData.detectorBinningValue;
      iParValues.numberOfOrientations = 1;

      // Build up the fParValues object
      PatternTools::FParValues fParValues;
      fParValues.omega = m_MP_Data.omega;
      fParValues.sigma = m_MP_Data.sigma;
      fParValues.pcPixelsX = detectorData.patternCenterX;
      fParValues.pcPixelsY = detectorData.patternCenterY;
      fParValues.scintillatorPixelSize = detectorData.scintillatorPixelSize;
      fParValues.scintillatorDist = detectorData.scintillatorDist;
      fParValues.detectorTiltAngle = detectorData.detectorTiltAngle;
      fParValues.beamCurrent = detectorData.beamCurrent;
      fParValues.dwellTime = detectorData.dwellTime;
      fParValues.gammaValue = patternData.gammaValue;

      std::vector<float> pattern =
          PatternTools::GeneratePattern(iParValues, fParValues, m_MP_Data.masterLPNHData, m_MP_Data.masterLPSHData, m_MP_Data.monteCarloSquareData, patternData.angles, index, m_Cancel);

      hsize_t xDim = static_cast<hsize_t>(iParValues.numOfPixelsX / iParValues.detectorBinningValue);
      hsize_t yDim = static_cast<hsize_t>(iParValues.numOfPixelsY / iParValues.detectorBinningValue);

      GLImageViewer::GLImageData imageData;
      bool success = generatePatternImage(imageData, pattern, xDim, yDim, 0);

      m_PatternDisplayWidget->loadImage(index, imageData);

      if(success)
      {
        model->setPatternStatus(index, PatternListItem::PatternStatus::Loaded);
      }
      else
      {
        model->setPatternStatus(index, PatternListItem::PatternStatus::Error);
      }

      m_NumOfFinishedPatternsLock.acquire();
      m_NumOfFinishedPatterns++;
      emit newProgressBarValue(m_NumOfFinishedPatterns);
      m_NumOfFinishedPatternsLock.release();

      emit rowDataChanged(modelIndex, modelIndex);
    }
  }
}

// -----------------------------------------------------------------------------
//
// -----------------------------------------------------------------------------
bool PatternDisplayController::generatePatternImage(GLImageViewer::GLImageData& imageData, const std::vector<float> &pattern, hsize_t xDim, hsize_t yDim, hsize_t zValue)
{
  AbstractImageGenerator::Pointer imgGen = ImageGenerator<float>::New(pattern, xDim, yDim, zValue);
  imgGen->createImage();

  imageData.image = imgGen->getGeneratedImage();

  VariantPair variantPair = imgGen->getMinMaxPair();
  imageData.minValue = variantPair.first.toFloat();
  imageData.maxValue = variantPair.second.toFloat();

  return true;
}

// -----------------------------------------------------------------------------
//
// -----------------------------------------------------------------------------
void PatternDisplayController::generatePatternImages(SimulatedPatternDisplayWidget::PatternDisplayData patternData, const PatternDisplayController::DetectorData& detectorData)
{
  m_NumOfFinishedPatterns = 0;
  m_NumOfFinishedPatternThreads = 0;
  m_CurrentOrder.clear();
  m_PriorityOrder.clear();
  m_PatternWatchers.clear();

  std::vector<float> eulerAngles = patternData.angles;
  size_t angleCount = eulerAngles.size() / 3;
  emit newProgressBarMaximumValue(angleCount);

  PatternListModel* model = PatternListModel::Instance();
  for(int i = 0; i < angleCount; i++)
  {
    model->setPatternStatus(i, PatternListItem::PatternStatus::WaitingToLoad);
    if(i == patternData.currentRow)
    {
      // We want to render the current index first
      m_CurrentOrder.push_front(i);
    }
    else
    {
      m_CurrentOrder.push_back(i);
    }
  }

  size_t threads = QThreadPool::globalInstance()->maxThreadCount();
  for(int i = 0; i < threads; i++)
  {
    QSharedPointer<QFutureWatcher<void>> watcher(new QFutureWatcher<void>());
    connect(watcher.data(), SIGNAL(finished()), this, SLOT(patternThreadFinished()));

    QFuture<void> future = QtConcurrent::run(this, &PatternDisplayController::generatePatternImagesUsingThread, patternData, detectorData);
    watcher->setFuture(future);

    m_PatternWatchers.push_back(watcher);
  }
}

// -----------------------------------------------------------------------------
//
// -----------------------------------------------------------------------------
void PatternDisplayController::addPriorityIndex(size_t index)
{
  m_PriorityOrder.push_back(index);
}

// -----------------------------------------------------------------------------
//
// -----------------------------------------------------------------------------
void PatternDisplayController::updateMPImage(MPMCDisplayWidget::MPMCData mpData)
{
  QImage image;
  VariantPair variantPair;
  MPMCDisplayWidget::ProjectionMode mode = mpData.mode;
  int energyBin = mpData.energyBin;
  float keV;

  // If any of the arrays are going to go out of bounds, set a blank image with blank data
  if((mode == MPMCDisplayWidget::ProjectionMode::Lambert_Square && energyBin > m_MasterLPNHImageGenerators.size()) ||
     (mode == MPMCDisplayWidget::ProjectionMode::Lambert_Circle && energyBin > m_MasterCircleImageGenerators.size()) ||
     (mode == MPMCDisplayWidget::ProjectionMode::Stereographic && energyBin > m_MasterStereoImageGenerators.size()))
  {
    image = QImage();
    variantPair.first = 0;
    variantPair.second = 0;
    keV = 0;
  }
  else
  {
    if(mode == MPMCDisplayWidget::ProjectionMode::Lambert_Square)
    {
      AbstractImageGenerator::Pointer imageGen = m_MasterLPNHImageGenerators[energyBin - 1];
      image = imageGen->getGeneratedImage();
      variantPair = imageGen->getMinMaxPair();
    }
    else if(mode == MPMCDisplayWidget::ProjectionMode::Lambert_Circle)
    {
      AbstractImageGenerator::Pointer imageGen = m_MasterCircleImageGenerators[energyBin - 1];
      image = imageGen->getGeneratedImage();
      variantPair = imageGen->getMinMaxPair();
    }
    else if(mode == MPMCDisplayWidget::ProjectionMode::Stereographic)
    {
      AbstractImageGenerator::Pointer imageGen = m_MasterStereoImageGenerators[energyBin - 1];
      image = imageGen->getGeneratedImage();
      variantPair = imageGen->getMinMaxPair();
    }

    keV = m_MP_Data.ekevs.at(energyBin - 1);
  }

  GLImageViewer::GLImageData imageData;
  imageData.image = image;

  imageData.minValue = variantPair.first.toFloat();
  imageData.maxValue = variantPair.second.toFloat();
  imageData.keVValue = keV;

  emit mpImageNeedsDisplayed(imageData);
}

// -----------------------------------------------------------------------------
//
// -----------------------------------------------------------------------------
void PatternDisplayController::updateMCImage(MPMCDisplayWidget::MPMCData mcData)
{
  QImage image;
  VariantPair variantPair;
  MPMCDisplayWidget::ProjectionMode mode = mcData.mode;
  int energyBin = mcData.energyBin;
  float keV;

  // If any of the arrays are going to go out of bounds, set a blank image with blank data
  if((mode == MPMCDisplayWidget::ProjectionMode::Lambert_Square && energyBin > m_MCSquareImageGenerators.size()) ||
     (mode == MPMCDisplayWidget::ProjectionMode::Lambert_Circle && energyBin > m_MCCircleImageGenerators.size()) ||
     (mode == MPMCDisplayWidget::ProjectionMode::Stereographic && energyBin > m_MCStereoImageGenerators.size()))
  {
    image = QImage();
    variantPair.first = 0;
    variantPair.second = 0;
    keV = 0;
  }
  else
  {
    if(mode == MPMCDisplayWidget::ProjectionMode::Lambert_Square)
    {
      AbstractImageGenerator::Pointer imageGen = m_MCSquareImageGenerators[energyBin - 1];
      image = imageGen->getGeneratedImage();
      variantPair = imageGen->getMinMaxPair();
    }
    else if(mode == MPMCDisplayWidget::ProjectionMode::Lambert_Circle)
    {
      AbstractImageGenerator::Pointer imageGen = m_MCCircleImageGenerators[energyBin - 1];
      image = imageGen->getGeneratedImage();
      variantPair = imageGen->getMinMaxPair();
    }
    else if(mode == MPMCDisplayWidget::ProjectionMode::Stereographic)
    {
      AbstractImageGenerator::Pointer imageGen = m_MCStereoImageGenerators[energyBin - 1];
      image = imageGen->getGeneratedImage();
      variantPair = imageGen->getMinMaxPair();
    }

    keV = m_MP_Data.ekevs.at(energyBin - 1);
  }

  GLImageViewer::GLImageData imageData;
  imageData.image = image;
  imageData.minValue = variantPair.first.toFloat();
  imageData.maxValue = variantPair.second.toFloat();
  imageData.keVValue = keV;

  emit mcImageNeedsDisplayed(imageData);
}

// -----------------------------------------------------------------------------
//
// -----------------------------------------------------------------------------
void PatternDisplayController::patternThreadFinished()
{
  m_NumOfFinishedPatternThreads++;
  if(m_NumOfFinishedPatternThreads == QThreadPool::globalInstance()->maxThreadCount())
  {
    m_Cancel = false;
    emit patternGenerationFinished();
  }
}

// -----------------------------------------------------------------------------
//
// -----------------------------------------------------------------------------
bool PatternDisplayController::validateDetectorValues(PatternDisplayController::DetectorData data)
{
  if(data.masterFilePath.isEmpty())
  {
    QString ss = QObject::tr("The master file path must be set.");
    emit errorMessageGenerated(ss);
    return false;
  }
  QFileInfo fi(data.masterFilePath);
  if(!fi.exists())
  {
    QString ss = QObject::tr("The master file path '%1' does not exist.").arg(data.masterFilePath);
    emit errorMessageGenerated(ss);
    return false;
  }
  QString suffix = fi.completeSuffix();
  if(suffix != "h5" && suffix != "dream3d")
  {
    QString ss = QObject::tr("The master file path '%1' is not an HDF5 file.").arg(data.masterFilePath);
    emit errorMessageGenerated(ss);
    return false;
  }

  return true;
}

// -----------------------------------------------------------------------------
//
// -----------------------------------------------------------------------------
void PatternDisplayController::cancelGeneration()
{
  m_Cancel = true;
}
