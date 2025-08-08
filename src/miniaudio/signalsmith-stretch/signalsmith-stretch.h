#ifndef SIGNALSMITH_STRETCH_H
#define SIGNALSMITH_STRETCH_H
#include "dsp/delay.h"
#include "dsp/perf.h"
#include "dsp/spectral.h"

SIGNALSMITH_DSP_VERSION_CHECK(1, 3, 3); // Check version is compatible
#include <algorithm>
#include <functional>
#include <random>
#include <vector>

namespace signalsmith
{
    namespace stretch
    {
        const float noiseFloor = 1e-15f;
        const float maxCleanStretch = 2; // time-stretch ratio before we start randomising phases

        struct Band
        {
            std::complex<float> input, prevInput{0};
            std::complex<float> output, prevOutput{0};
            float inputEnergy;
        };

        struct Prediction
        {
            float energy = 0;
            std::complex<float> input;
            std::complex<float> shortVerticalTwist, longVerticalTwist;

            std::complex<float> makeOutput(std::complex<float> &phase)
            {
                float phaseNorm = std::norm(phase);
                if (phaseNorm <= noiseFloor)
                {
                    phase = input; // prediction is too weak, fall back to the input
                    phaseNorm = std::norm(input) + noiseFloor;
                }
                return phase * std::sqrt(energy / phaseNorm);
            }
        };

        struct Peak
        {
            float input, output;
        };

        struct PitchMapPoint
        {
            float inputBin, freqGrad;
        };

        class SignalsmithStretch
        {
        public:
            SignalsmithStretch() : randomEngine(std::random_device{}()) {}
            SignalsmithStretch(long seed) : randomEngine(seed) {}

            int blockSamples() const;
            int intervalSamples() const;
            int inputLatency() const;
            int outputLatency() const;

            void reset();
            void presetDefault(int nChannels, float sampleRate);
            void presetCheaper(int nChannels, float sampleRate);
            void configure(int nChannels, int blockSamples, int intervalSamples);
            void setTransposeFactor(float multiplier, float tonalityLimit = 0);
            void setTransposeSemitones(float semitones, float tonalityLimit = 0);
            void setFreqMap(std::function<float(float)> inputToOutput);
            void process(
                float *inputs,
                int inputSamples,
                float *outputs,
                int outputSamples);
            void flush(
                float *outputs,
                int outputSamples);
            void seek(
                float *inputs,
                int inputSamples,
                float playbackRate);

        private:
            int silenceCounter = 0;
            bool silenceFirst = true;
            bool flushed = false;
            bool didSeek = false;

            float freqMultiplier = 1;
            float freqTonalityLimit = 0.5;
            std::function<float(float)> customFreqMap = nullptr;

            signalsmith::spectral::STFT<float> stft{0, 1, 1};
            signalsmith::delay::MultiBuffer<float> inputBuffer;
            int channels = 0, bands = 0;
            int prevInputOffset = -1;
            float seekTimeFactor = 1;
            std::vector<float> timeBuffer;

            std::vector<std::complex<float>> rotCentreSpectrum, rotPrevInterval;
            SIGNALSMITH_INLINE float bandToFreq(float b) const;
            SIGNALSMITH_INLINE float freqToBand(float f) const;
            SIGNALSMITH_INLINE void timeShiftPhases(float shiftSamples, std::vector<std::complex<float>> &output) const;

            std::vector<Band> channelBands;
            SIGNALSMITH_INLINE Band *bandsForChannel(int channel);

            std::vector<Peak> peaks;
            std::vector<float> energy, smoothedEnergy;
            std::vector<PitchMapPoint> outputMap;
            std::vector<Prediction> channelPredictions;
            Prediction *predictionsForChannel(int c);

            std::default_random_engine randomEngine;

            SIGNALSMITH_INLINE void processSpectrum(bool newSpectrum, float timeFactor);
            SIGNALSMITH_INLINE void smoothEnergy(float smoothingBins);
            SIGNALSMITH_INLINE float mapFreq(float freq) const;
            SIGNALSMITH_INLINE void findPeaks(float smoothingBins);
            SIGNALSMITH_INLINE void updateOutputMap();
        };

    } // namespace stretch
} // namespace signalsmith

#endif // include guard

#define SIGNALSMITH_STRETCH_IMPLEMENTATION
#ifdef SIGNALSMITH_STRETCH_IMPLEMENTATION

namespace signalsmith
{
    namespace stretch
    {
        // PUBLIC API

        int SignalsmithStretch::blockSamples() const
        {
            return stft.windowSize();
        }
        int SignalsmithStretch::intervalSamples() const
        {
            return stft.interval();
        }
        int SignalsmithStretch::inputLatency() const
        {
            return stft.windowSize() / 2;
        }
        int SignalsmithStretch::outputLatency() const
        {
            return stft.windowSize() - inputLatency();
        }

        void SignalsmithStretch::reset()
        {
            stft.reset();
            inputBuffer.reset();
            prevInputOffset = -1;
            channelBands.assign(channelBands.size(), Band());
            silenceCounter = 2 * stft.windowSize();
            flushed = true;
            didSeek = false;
        }

        // Configures using a default preset
        void SignalsmithStretch::presetDefault(int nChannels, float sampleRate)
        {
            configure(
                nChannels,
                static_cast<int>(sampleRate * 0.12),
                static_cast<int>(sampleRate * 0.03));
        }

        void SignalsmithStretch::presetCheaper(int nChannels, float sampleRate)
        {
            configure(
                nChannels,
                static_cast<int>(sampleRate * 0.1),
                static_cast<int>(sampleRate * 0.04));
        }

        // Manual setup
        void SignalsmithStretch::configure(int nChannels, int blockSamples, int intervalSamples)
        {
            channels = nChannels;
            stft.resize(channels, blockSamples, intervalSamples);
            bands = stft.bands();
            inputBuffer.resize(channels, blockSamples + intervalSamples + 1);
            timeBuffer.assign(stft.fftSize(), 0);
            channelBands.assign(bands * channels, Band());

            // Various phase rotations
            rotCentreSpectrum.resize(bands);
            rotPrevInterval.assign(bands, 0);
            timeShiftPhases(blockSamples * float(-0.5), rotCentreSpectrum);
            timeShiftPhases(static_cast<float>(-intervalSamples), rotPrevInterval);
            peaks.reserve(bands);
            energy.resize(bands);
            smoothedEnergy.resize(bands);
            outputMap.resize(bands);
            channelPredictions.resize(channels * bands);
        }

        /// Frequency multiplier, and optional tonality limit (as multiple of sample-rate)
        void SignalsmithStretch::setTransposeFactor(float multiplier, float tonalityLimit)
        {
            freqMultiplier = multiplier;
            if (tonalityLimit > 0)
            {
                freqTonalityLimit = tonalityLimit / std::sqrt(multiplier); // compromise between input and output limits
            }
            else
            {
                freqTonalityLimit = 1;
            }
            customFreqMap = nullptr;
        }
        void SignalsmithStretch::setTransposeSemitones(float semitones, float tonalityLimit)
        {
            setTransposeFactor(std::pow(2.0f, semitones / 12.0f), tonalityLimit);
            customFreqMap = nullptr;
        }
        // Sets a custom frequency map - should be monotonically increasing
        void SignalsmithStretch::setFreqMap(std::function<float(float)> inputToOutput)
        {
            customFreqMap = inputToOutput;
        }

        Prediction *SignalsmithStretch::predictionsForChannel(int c)
        {
            return channelPredictions.data() + c * bands;
        }

        void SignalsmithStretch::process(
            float *inputs,
            int inputSamples,
            float *outputs,
            int outputSamples)
        {
            float totalEnergy = 0;
            for (int c = 0; c < channels; ++c)
            {
                for (int i = 0; i < inputSamples; ++i)
                {
                    float s = (&inputs[0] + c)[i * channels];
                    totalEnergy += std::pow(s, 2.0f);
                }
            }
            if (totalEnergy < noiseFloor)
            {
                if (silenceCounter >= 2 * stft.windowSize())
                {
                    if (silenceFirst)
                    {
                        silenceFirst = false;
                        for (auto &b : channelBands)
                        {
                            b.input = b.prevInput = b.output = b.prevOutput = 0;
                            b.inputEnergy = 0;
                        }
                    }

                    if (inputSamples > 0)
                    {
                        // copy from the input, wrapping around if needed
                        for (int outputIndex = 0; outputIndex < outputSamples; ++outputIndex)
                        {
                            int inputIndex = outputIndex % inputSamples;
                            for (int c = 0; c < channels; ++c)
                            {
                                (&outputs[0] + c)[outputIndex * channels] = (&inputs[0] + c)[inputIndex * channels];
                            }
                        }
                    }
                    else
                    {
                        for (int c = 0; c < channels; ++c)
                        {
                            // auto &&outputChannel = outputs[c];
                            for (int outputIndex = 0; outputIndex < outputSamples; ++outputIndex)
                            {
                                // outputChannel[outputIndex * channels] = 0;
                                (&outputs[0] + c)[outputIndex * channels] = 0;
                            }
                        }
                    }

                    // Store input in history buffer
                    for (int c = 0; c < channels; ++c)
                    {
                        // auto &&inputChannel = inputs[c];
                        auto &&bufferChannel = inputBuffer[c];
                        int startIndex = std::max<int>(0, inputSamples - stft.windowSize());
                        for (int i = startIndex; i < inputSamples; ++i)
                        {
                            bufferChannel[i] = (&inputs[0] + c)[i * channels];
                        }
                    }
                    inputBuffer += inputSamples;
                    return;
                }
                else
                {
                    silenceCounter += inputSamples;
                }
            }
            else
            {
                silenceCounter = 0;
                silenceFirst = true;
            }

            for (int outputIndex = 0; outputIndex < outputSamples; ++outputIndex)
            {
                stft.ensureValid(outputIndex, [&](int outputOffset)
                                 {
                    // Time to process a spectrum!  Where should it come from in the input?
                    int inputOffset = static_cast<int>(std::round(outputOffset * float(inputSamples) / outputSamples) - stft.windowSize());
                    int inputInterval = inputOffset - prevInputOffset;
                    prevInputOffset = inputOffset;

                    bool newSpectrum = didSeek || (inputInterval > 0);
                    if (newSpectrum) {
                        for (int c = 0; c < channels; ++c) {
                            // Copy from the history buffer, if needed
                            auto &&bufferChannel = inputBuffer[c];
                            for (int i = 0; i < -inputOffset; ++i) {
                                timeBuffer[i] = bufferChannel[i + inputOffset];
                            }
                            // Copy the rest from the input
                            // auto &&inputChannel = inputs[c];
                            for (int i = std::max<int>(0, -inputOffset); i < stft.windowSize(); ++i) {
                                timeBuffer[i] = (&inputs[0] + c)[(i + inputOffset) * channels]; // inputChannel[i + inputOffset];
                            }
                            stft.analyse(c, timeBuffer);
                        }

                        flushed = true;

                        for (int c = 0; c < channels; ++c) {
                            auto   channelBands = bandsForChannel(c);
                            auto &&spectrumBands = stft.spectrum[c];
                            for (int b = 0; b < bands; ++b) {
                                channelBands[b].input = signalsmith::perf::mul(spectrumBands[b], rotCentreSpectrum[b]);
                            }
                        }

                        if (didSeek || inputInterval != stft.interval()) { // make sure the previous input is the correct distance in the past
                            int prevIntervalOffset = inputOffset - stft.interval();
                            for (int c = 0; c < channels; ++c) {
                                // Copy from the history buffer, if needed
                                auto &&bufferChannel = inputBuffer[c];
                                for (int i = 0; i < (std::min)(-prevIntervalOffset, stft.windowSize()); ++i) {
                                    timeBuffer[i] = bufferChannel[i + prevIntervalOffset];
                                }
                                // Copy the rest from the input
                                // auto &&inputChannel = inputs[c];
                                for (int i = (std::max)(0, -prevIntervalOffset); i < stft.windowSize(); ++i) {
                                    timeBuffer[i] = (&inputs[0] + c)[(i + prevIntervalOffset) * channels]; // inputChannel[i + prevIntervalOffset];
                                }
                                stft.analyse(c, timeBuffer);
                            }
                            for (int c = 0; c < channels; ++c) {
                                auto   channelBands = bandsForChannel(c);
                                auto &&spectrumBands = stft.spectrum[c];
                                for (int b = 0; b < bands; ++b) {
                                    channelBands[b].prevInput = signalsmith::perf::mul(spectrumBands[b], rotCentreSpectrum[b]);
                                }
                            }
                        }
                    }

                    float timeFactor = didSeek ? seekTimeFactor : stft.interval() / (std::max)(1.0f, (float)inputInterval);
                    processSpectrum(newSpectrum, timeFactor);
                    didSeek = false;

                    for (int c = 0; c < channels; ++c) {
                        auto   channelBands = bandsForChannel(c);
                        auto &&spectrumBands = stft.spectrum[c];
                        for (int b = 0; b < bands; ++b) {
                            spectrumBands[b] = signalsmith::perf::mul<true>(channelBands[b].output, rotCentreSpectrum[b]);
                        }
                    } });

                for (int c = 0; c < channels; ++c)
                {
                    // auto &&outputChannel = outputs[c];
                    auto &&stftChannel = stft[c];
                    // outputChannel[outputIndex] = stftChannel[outputIndex];
                    (&outputs[0] + c)[outputIndex * channels] = stftChannel[outputIndex];
                }
            }

            // Store input in history buffer
            for (int c = 0; c < channels; ++c)
            {
                // auto &&inputChannel = inputs[c];
                auto &&bufferChannel = inputBuffer[c];
                int startIndex = std::max<int>(0, inputSamples - stft.windowSize());
                for (int i = startIndex; i < inputSamples; ++i)
                {
                    bufferChannel[i] = (&inputs[0] + c)[i * channels];
                }
            }
            inputBuffer += inputSamples;
            stft += outputSamples;
            prevInputOffset -= inputSamples;
        }

        void SignalsmithStretch::flush(
            float *outputs,
            int outputSamples)
        {
            int plainOutput = std::min<int>(outputSamples, stft.windowSize());
            int foldedBackOutput = std::min<int>(outputSamples, stft.windowSize() - plainOutput);

            for (int c = 0; c < channels; ++c)
            {
                auto &&stftChannel = stft[c];

                for (int i = 0; i < plainOutput; ++i)
                {
                    (&outputs[0] + c)[i * channels] = stftChannel[i];
                }
                for (int i = 0; i < foldedBackOutput; ++i)
                {
                    (&outputs[0] + c)[(outputSamples - 1 - i) * channels] -= stftChannel[plainOutput + i];
                }
                for (int i = 0; i < plainOutput + foldedBackOutput; ++i)
                {
                    stftChannel[i] = 0;
                }
            }

            stft += plainOutput + foldedBackOutput;

            for (int c = 0; c < channels; ++c)
            {
                auto channelBands = bandsForChannel(c);
                for (int b = 0; b < bands; ++b)
                {
                    channelBands[b].prevInput = channelBands[b].prevOutput = 0;
                }
            }

            flushed = true;
        }

        void SignalsmithStretch::seek(
            float *inputs,
            int inputSamples,
            float playbackRate)
        {
            inputBuffer.reset();
            float totalEnergy = 0;
            for (int c = 0; c < channels; ++c)
            {
                auto &&bufferChannel = inputBuffer[c];
                int startIndex = std::max<int>(0, inputSamples - stft.windowSize() - stft.interval());
                for (int i = startIndex; i < inputSamples; ++i)
                {
                    float s = (&inputs[0] + c)[i * channels];
                    totalEnergy += s * s;
                    bufferChannel[i] = s;
                }
            }

            if (totalEnergy >= noiseFloor)
            {
                silenceCounter = 0;
                silenceFirst = true;
            }

            inputBuffer += inputSamples;
            didSeek = true;
            seekTimeFactor = (playbackRate * stft.interval() > 1) ? 1 / playbackRate : stft.interval();
        }

        // PRIVATE IMPLEMENTATION
        SIGNALSMITH_INLINE float
        SignalsmithStretch::bandToFreq(float b) const
        {
            return (b + float(0.5)) / stft.fftSize();
        }

        SIGNALSMITH_INLINE float SignalsmithStretch::freqToBand(float f) const
        {
            return f * stft.fftSize() - float(0.5);
        }

        SIGNALSMITH_INLINE void SignalsmithStretch::timeShiftPhases(float shiftSamples, std::vector<std::complex<float>> &output) const
        {
            for (int b = 0; b < bands; ++b)
            {
                float phase = bandToFreq((float)b) * shiftSamples * float(-2 * M_PI);
                output[b] = {std::cos(phase), std::sin(phase)};
            }
        }

        SIGNALSMITH_INLINE Band *SignalsmithStretch::bandsForChannel(int channel)
        {
            return channelBands.data() + channel * bands;
        }

        template <std::complex<float> Band::*member>
        SIGNALSMITH_INLINE std::complex<float> getBand(std::vector<Band> &channelBands, int bands, int channel, int index)
        {
            if (index < 0 || index >= bands)
                return 0;
            return channelBands[index + channel * bands].*member;
        }
        template <std::complex<float> Band::*member>
        SIGNALSMITH_INLINE std::complex<float> getFractional(std::vector<Band> &channelBands, int bands, int channel, int lowIndex, float fractional)
        {
            std::complex<float> low = getBand<member>(channelBands, bands, channel, lowIndex);
            std::complex<float> high = getBand<member>(channelBands, bands, channel, lowIndex + 1);
            return low + (high - low) * fractional;
        }
        template <std::complex<float> Band::*member>
        SIGNALSMITH_INLINE std::complex<float> getFractional(std::vector<Band> &channelBands, int bands, int channel, float inputIndex)
        {
            int lowIndex = static_cast<int>(std::floor(inputIndex));
            float fracIndex = inputIndex - lowIndex;
            return getFractional<member>(channelBands, bands, channel, lowIndex, fracIndex);
        }
        template <float Band::*member>
        SIGNALSMITH_INLINE float getBand(std::vector<Band> &channelBands, int bands, int channel, int index)
        {
            if (index < 0 || index >= bands)
                return 0;
            return channelBands[index + channel * bands].*member;
        }
        template <float Band::*member>
        SIGNALSMITH_INLINE float getFractional(std::vector<Band> &channelBands, int bands, int channel, int lowIndex, float fractional)
        {
            float low = getBand<member>(channelBands, bands, channel, lowIndex);
            float high = getBand<member>(channelBands, bands, channel, lowIndex + 1);
            return low + (high - low) * fractional;
        }
        template <float Band::*member>
        SIGNALSMITH_INLINE float getFractional(std::vector<Band> &channelBands, int bands, int channel, float inputIndex)
        {
            int lowIndex = std::floor(inputIndex);
            float fracIndex = inputIndex - lowIndex;
            return getFractional<member>(channelBands, bands, channel, lowIndex, fracIndex);
        }

        SIGNALSMITH_INLINE void SignalsmithStretch::processSpectrum(bool newSpectrum, float timeFactor)
        {
            timeFactor = (std::max)(timeFactor, 1.0f / maxCleanStretch);
            bool randomTimeFactor = (timeFactor > maxCleanStretch);
            std::uniform_real_distribution<float> timeFactorDist(maxCleanStretch * 2 * randomTimeFactor - timeFactor, timeFactor);

            if (newSpectrum)
            {
                for (int c = 0; c < channels; ++c)
                {
                    auto bins = bandsForChannel(c);
                    for (int b = 0; b < bands; ++b)
                    {
                        auto &bin = bins[b];
                        bin.prevOutput = signalsmith::perf::mul(bin.prevOutput, rotPrevInterval[b]);
                        bin.prevInput = signalsmith::perf::mul(bin.prevInput, rotPrevInterval[b]);
                    }
                }
            }

            float smoothingBins = float(stft.fftSize()) / stft.interval();
            int longVerticalStep = static_cast<int>(std::round(smoothingBins));
            if (customFreqMap || freqMultiplier != 1)
            {
                findPeaks(smoothingBins);
                updateOutputMap();
            }
            else
            { // we're not pitch-shifting, so no need to find peaks etc.
                for (int c = 0; c < channels; ++c)
                {
                    Band *bins = bandsForChannel(c);
                    for (int b = 0; b < bands; ++b)
                    {
                        bins[b].inputEnergy = std::norm(bins[b].input);
                    }
                }
                for (int b = 0; b < bands; ++b)
                {
                    outputMap[b] = {float(b), 1}; //
                }
            }

            // Preliminary output prediction from phase-vocoder
            for (int c = 0; c < channels; ++c)
            {
                Band *bins = bandsForChannel(c);
                auto *predictions = predictionsForChannel(c);
                for (int b = 0; b < bands; ++b)
                {
                    auto mapPoint = outputMap[b];
                    int lowIndex = static_cast<int>(std::floor(mapPoint.inputBin));
                    float fracIndex = mapPoint.inputBin - lowIndex;

                    Prediction &prediction = predictions[b];
                    float prevEnergy = prediction.energy;
                    prediction.energy = getFractional<&Band::inputEnergy>(channelBands, bands, c, lowIndex, fracIndex);
                    prediction.energy *= (std::max)(0.0f, mapPoint.freqGrad); // scale the energy according to local stretch factor
                    prediction.input = getFractional<&Band::input>(channelBands, bands, c, lowIndex, fracIndex);

                    auto &outputBin = bins[b];
                    std::complex<float> prevInput = getFractional<&Band::prevInput>(channelBands, bands, c, lowIndex, fracIndex);
                    std::complex<float> freqTwist = signalsmith::perf::mul<true>(prediction.input, prevInput);
                    std::complex<float> phase = signalsmith::perf::mul(outputBin.prevOutput, freqTwist);
                    outputBin.output = phase / ((std::max)(prevEnergy, prediction.energy) + noiseFloor);

                    if (b > 0)
                    {
                        float binTimeFactor = randomTimeFactor ? timeFactorDist(randomEngine) : timeFactor;
                        std::complex<float> downInput = getFractional<&Band::input>(channelBands, bands, c, mapPoint.inputBin - binTimeFactor);
                        prediction.shortVerticalTwist = signalsmith::perf::mul<true>(prediction.input, downInput);
                        if (b >= longVerticalStep)
                        {
                            std::complex<float> longDownInput = getFractional<&Band::input>(channelBands, bands, c, mapPoint.inputBin - longVerticalStep * binTimeFactor);
                            prediction.longVerticalTwist = signalsmith::perf::mul<true>(prediction.input, longDownInput);
                        }
                        else
                        {
                            prediction.longVerticalTwist = 0;
                        }
                    }
                    else
                    {
                        prediction.shortVerticalTwist = prediction.longVerticalTwist = 0;
                    }
                }
            }

            // Re-predict using phase differences between frequencies
            for (int b = 0; b < bands; ++b)
            {
                // Find maximum-energy channel and calculate that
                int maxChannel = 0;
                float maxEnergy = predictionsForChannel(0)[b].energy;
                for (int c = 1; c < channels; ++c)
                {
                    float e = predictionsForChannel(c)[b].energy;
                    if (e > maxEnergy)
                    {
                        maxChannel = c;
                        maxEnergy = e;
                    }
                }

                auto *predictions = predictionsForChannel(maxChannel);
                auto &prediction = predictions[b];
                auto *bins = bandsForChannel(maxChannel);
                auto &outputBin = bins[b];

                std::complex<float> phase = 0;

                // Upwards vertical steps
                if (b > 0)
                {
                    auto &downBin = bins[b - 1];
                    phase += signalsmith::perf::mul(downBin.output, prediction.shortVerticalTwist);

                    if (b >= longVerticalStep)
                    {
                        auto &longDownBin = bins[b - longVerticalStep];
                        phase += signalsmith::perf::mul(longDownBin.output, prediction.longVerticalTwist);
                    }
                }
                // Downwards vertical steps
                if (b < bands - 1)
                {
                    auto &upPrediction = predictions[b + 1];
                    auto &upBin = bins[b + 1];
                    phase += signalsmith::perf::mul<true>(upBin.output, upPrediction.shortVerticalTwist);

                    if (b < bands - longVerticalStep)
                    {
                        auto &longUpPrediction = predictions[b + longVerticalStep];
                        auto &longUpBin = bins[b + longVerticalStep];
                        phase += signalsmith::perf::mul<true>(longUpBin.output, longUpPrediction.longVerticalTwist);
                    }
                }

                outputBin.output = prediction.makeOutput(phase);

                // All other bins are locked in phase
                for (int c = 0; c < channels; ++c)
                {
                    if (c != maxChannel)
                    {
                        auto &channelBin = bandsForChannel(c)[b];
                        auto &channelPrediction = predictionsForChannel(c)[b];

                        std::complex<float> channelTwist = signalsmith::perf::mul<true>(channelPrediction.input, prediction.input);
                        std::complex<float> channelPhase = signalsmith::perf::mul(outputBin.output, channelTwist);
                        channelBin.output = channelPrediction.makeOutput(channelPhase);
                    }
                }
            }

            if (newSpectrum)
            {
                for (auto &bin : channelBands)
                {
                    bin.prevOutput = bin.output;
                    bin.prevInput = bin.input;
                }
            }
            else
            {
                for (auto &bin : channelBands)
                    bin.prevOutput = bin.output;
            }
        }

        SIGNALSMITH_INLINE void SignalsmithStretch::smoothEnergy(float smoothingBins)
        {
            float smoothingSlew = 1 / (1 + smoothingBins * float(0.5));
            for (auto &e : energy)
                e = 0;
            for (int c = 0; c < channels; ++c)
            {
                Band *bins = bandsForChannel(c);
                for (int b = 0; b < bands; ++b)
                {
                    float e = std::norm(bins[b].input);
                    bins[b].inputEnergy = e; // Used for interpolating prediction energy
                    energy[b] += e;
                }
            }
            for (int b = 0; b < bands; ++b)
            {
                smoothedEnergy[b] = energy[b];
            }
            float e = 0;
            for (int repeat = 0; repeat < 2; ++repeat)
            {
                for (int b = bands - 1; b >= 0; --b)
                {
                    e += (smoothedEnergy[b] - e) * smoothingSlew;
                    smoothedEnergy[b] = e;
                }
                for (int b = 0; b < bands; ++b)
                {
                    e += (smoothedEnergy[b] - e) * smoothingSlew;
                    smoothedEnergy[b] = e;
                }
            }
        }

        SIGNALSMITH_INLINE float SignalsmithStretch::mapFreq(float freq) const
        {
            if (customFreqMap)
                return customFreqMap(freq);
            if (freq > freqTonalityLimit)
            {
                float diff = freq - freqTonalityLimit;
                return freqTonalityLimit * freqMultiplier + diff;
            }
            return freq * freqMultiplier;
        }

        // Identifies spectral peaks using energy across all channels
        SIGNALSMITH_INLINE void SignalsmithStretch::findPeaks(float smoothingBins)
        {
            smoothEnergy(smoothingBins);

            peaks.resize(0);

            int start = 0;
            while (start < bands)
            {
                if (energy[start] > smoothedEnergy[start])
                {
                    int end = start;
                    float bandSum = 0, energySum = 0;
                    while (end < bands && energy[end] > smoothedEnergy[end])
                    {
                        bandSum += end * energy[end];
                        energySum += energy[end];
                        ++end;
                    }
                    float avgBand = bandSum / energySum;
                    float avgFreq = bandToFreq(avgBand);
                    peaks.emplace_back(Peak{avgBand, freqToBand(mapFreq(avgFreq))});

                    start = end;
                }
                ++start;
            }
        }

        SIGNALSMITH_INLINE void SignalsmithStretch::updateOutputMap()
        {
            if (peaks.empty())
            {
                for (int b = 0; b < bands; ++b)
                {
                    outputMap[b] = {float(b), 1};
                }
                return;
            }
            float bottomOffset = peaks[0].input - peaks[0].output;
            for (int b = 0; b < (std::min)(bands, (int)std::ceil(peaks[0].output)); ++b)
            {
                outputMap[b] = {b + bottomOffset, 1};
            }
            // Interpolate between points
            for (size_t p = 1; p < peaks.size(); ++p)
            {
                const Peak &prev = peaks[p - 1], &next = peaks[p];
                float rangeScale = 1 / (next.output - prev.output);
                float outOffset = prev.input - prev.output;
                float outScale = next.input - next.output - prev.input + prev.output;
                float gradScale = outScale * rangeScale;
                int startBin = (std::max)(0, (int)std::ceil(prev.output));
                int endBin = (std::min)(bands, (int)std::ceil(next.output));
                for (int b = startBin; b < endBin; ++b)
                {
                    float r = (b - prev.output) * rangeScale;
                    float h = r * r * (3 - 2 * r);
                    float outB = b + outOffset + h * outScale;

                    float gradH = 6 * r * (1 - r);
                    float gradB = 1 + gradH * gradScale;

                    outputMap[b] = {outB, gradB};
                }
            }
            float topOffset = peaks.back().input - peaks.back().output;
            for (int b = (std::max)(0, (int)peaks.back().output); b < bands; ++b)
            {
                outputMap[b] = {b + topOffset, 1};
            }
        }

    } // namespace stretch
} // namespace signalsmith

#endif
