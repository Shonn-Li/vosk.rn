import Foundation
import AVFoundation
import React

// Enhanced result structure to include word timestamps
struct VoskResult: Codable {
    // Partial result
    var partial: String?
    // Complete result
    var text: String?
    // Word results with timestamps
    var result: [WordResult]?
    
    struct WordResult: Codable {
        var conf: Float
        var end: Float
        var start: Float
        var word: String
    }
}

// Structure of options for start method
struct VoskStartOptions {
    // Grammar to use
    var grammar: [String]?
    // Timeout in milliseconds
    var timeout: Int?
    // Path to save audio recording
    var audioFilePath: String?
}
extension VoskStartOptions: Codable {
    init(dictionary: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: dictionary)
        self = try JSONDecoder().decode(VoskStartOptions.self, from: data)
    }
    private enum CodingKeys: String, CodingKey {
        case grammar, timeout, audioFilePath
    }
}

@objc(Vosk)
class Vosk: RCTEventEmitter {
    // Class properties
    /// The current vosk model loaded
    var currentModel: VoskModel?
    /// The vosk recognizer
    var recognizer : OpaquePointer?
    /// The audioEngine used to pipe microphone to recognizer
    let audioEngine = AVAudioEngine()
    /// The audioEngine input
    var inputNode: AVAudioInputNode!
    /// The microphone input format
    var formatInput: AVAudioFormat!
    /// A queue to process datas
    var processingQueue: DispatchQueue!
    /// Keep the last processed result here
    var lastRecognizedResult: VoskResult?
    /// The timeout timer ref
    var timeoutTimer: Timer?
    /// The current grammar set
    var grammar: [String]?
    /// File to save audio recording
    var audioFile: AVAudioFile?
    /// Is recognition paused
    var isPaused: Bool = false
    /// Last volume update time for throttling
    var lastVolumeUpdateTime: Date = Date()
    /// Volume update interval in seconds
    let volumeUpdateInterval: TimeInterval = 0.1

    /// React member: has any JS event listener
    var hasListener: Bool = false

    fileprivate var wavWriter: WavWriter?

    // Class methods
    override init() {
        super.init()
        // Init the processing queue
        processingQueue = DispatchQueue(label: "recognizerQueue")
        // Create a new audio engine.
        inputNode = audioEngine.inputNode
    }

    deinit {
        // free the recognizer if it exists
        if recognizer != nil {
            vosk_recognizer_free(recognizer);
            recognizer = nil
        }
    }

    /// Called when React adds an event observer
    override func startObserving() {
        hasListener = true
    }

    /// Called when no more event observers are running
    override func stopObserving() {
        hasListener = false
    }

    /// React method to define allowed events
    @objc override func supportedEvents() -> [String]! {
        return ["onError", "onResult", "onFinalResult", "onPartialResult", "onTimeout", "onVolumeChanged"]
    }

    /// Load a Vosk model
    @objc(loadModel:withResolver:withRejecter:)
    func loadModel(name: String, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) -> Void {
        if currentModel != nil {
            currentModel = nil // deinit model
        }

        // Load the model in a try catch block
        do {
            try currentModel = VoskModel(name: name)
            if currentModel?.model == nil {
                reject("model_load_failed", "Failed to load Vosk model", nil)
                return
            }
            resolve(true)
        } catch {
            reject("model_load_failed", "Error loading Vosk model: \(error.localizedDescription)", error)
        }
    }

    /// Start speech recognition
    @objc(start:withResolver:withRejecter:)
    func start(rawOptions: [String: Any]?, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) -> Void {
        // First check if model is loaded
        guard let model = currentModel, model.model != nil else {
            reject("start", "No model loaded", nil)
            return
        }
        
        let audioSession = AVAudioSession.sharedInstance()

        var options: VoskStartOptions? = nil
        if let rawOptions = rawOptions {
            do {
                options = try VoskStartOptions(dictionary: rawOptions)
            } catch {
                print("Error parsing options: \(error)")
            }
        }

        // if grammar is set in options, override the current grammar
        var grammar: [String]?
        if let grammarOptions = options?.grammar, !grammarOptions.isEmpty {
            grammar = grammarOptions
        }

        // if timeout is set in options, handle it
        var timeout: Int?
        if let timeoutOptions = options?.timeout {
            timeout = timeoutOptions
        }
        
        // Check if we need to save audio to file
        var audioFilePath: String?
        if let path = options?.audioFilePath {
            audioFilePath = path
        }

        // Clean up any existing resources
        stopInternal(withoutEvents: true)
        
        do {
            // Configure audio session properly
            try audioSession.setCategory(.playAndRecord, 
                                        mode: .spokenAudio, 
                                        options: [.defaultToSpeaker, .allowBluetooth])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            
            // Get the input format after activating audio session
            formatInput = inputNode.inputFormat(forBus: 0)
            let sampleRate = formatInput.sampleRate.isFinite && formatInput.sampleRate > 0 ? formatInput.sampleRate : 16000
            let channelCount = formatInput.channelCount > 0 ? formatInput.channelCount : 1

            let formatPcm = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                          sampleRate: sampleRate,
                                          channels: channelCount,
                                          interleaved: true)

            guard let formatPcm = formatPcm else {
                reject("start", "Unable to create audio format", nil)
                return
            }
            
            // Create the recognizer
            if let grammar = grammar, !grammar.isEmpty {
                let jsonGrammar = try JSONEncoder().encode(grammar)
                if let jsonString = String(data: jsonGrammar, encoding: .utf8) {
                    recognizer = vosk_recognizer_new_grm(model.model, Float(sampleRate), jsonString)
                } else {
                    recognizer = vosk_recognizer_new(model.model, Float(sampleRate))
                }
            } else {
                recognizer = vosk_recognizer_new(model.model, Float(sampleRate))
            }
            
            guard recognizer != nil else {
                reject("start", "Failed to create Vosk recognizer", nil)
                return
            }
            
            // Enable word timestamps in the recognizer
            vosk_recognizer_set_words(recognizer, 1)
            
            // Create audio file for recording if path is provided
            if let path = audioFilePath {
                    wavWriter = WavWriter(filePath: path, 
                                        sampleRate: Int(sampleRate), 
                                        numChannels: Int(channelCount), 
                                        bitsPerSample: 16)
                    
                    if wavWriter == nil {
                        print("Failed to initialize WavWriter with path: \(path)")
                        // Continue even if WavWriter initialization fails
                    } else {
                        print("Successfully initialized WavWriter for path: \(path)")
                    }
                }
            
            // Reset pause state
            isPaused = false

            // Request microphone permission before installing tap
            audioSession.requestRecordPermission { [weak self] granted in
                guard let self = self else { return }
                
                if granted {
                    DispatchQueue.main.async {
                        do {
                            // Install the audio tap
                            self.installAudioTap(formatPcm: formatPcm, sampleRate: Float(sampleRate))
                            
                            // Start the audio engine
                            self.audioEngine.prepare()
                            try self.audioEngine.start()
                            
                            // Set up timeout if needed
                            if let timeout = timeout {
                                self.timeoutTimer = Timer.scheduledTimer(withTimeInterval: Double(timeout) / 1000, 
                                                                       repeats: false) { _ in
                                    self.processingQueue.async {
                                        self.stopInternal(withoutEvents: true)
                                        if self.hasListener {
                                            self.sendEvent(withName: "onTimeout", body: "")
                                        }
                                    }
                                }
                            }
                            
                            resolve("Recognizer successfully started")
                        } catch {
                            if self.hasListener {
                                self.sendEvent(withName: "onError", body: "Unable to start AVAudioEngine: \(error.localizedDescription)")
                            }
                            self.stopInternal(withoutEvents: true)
                            reject("start", "Unable to start AVAudioEngine: \(error.localizedDescription)", error)
                        }
                    }
                } else {
                    reject("permission_denied", "Microphone permission denied", nil)
                }
            }
        } catch {
            if hasListener {
                sendEvent(withName: "onError", body: "Unable to start AVAudioEngine: \(error.localizedDescription)")
            }
            stopInternal(withoutEvents: true)
            reject("start", "Unable to start AVAudioEngine: \(error.localizedDescription)", error)
        }
    }
    
    /// Install audio tap with the given format
    private func installAudioTap(formatPcm: AVAudioFormat, sampleRate: Float) {
        inputNode.installTap(onBus: 0,
                            bufferSize: UInt32(sampleRate / 10),
                            format: formatPcm) { [weak self] buffer, _ in
            guard let self = self, !self.isPaused else { return }
            
            self.processingQueue.async {
                // Calculate audio level (volume)
                self.calculateAndSendVolume(buffer: buffer)
                
                // Save audio to file using WavWriter if available
                if let writer = self.wavWriter, let channelData = buffer.int16ChannelData?[0] {
                    let frameCount = Int(buffer.frameLength)
                    writer.appendSamples(channelData, sampleCount: frameCount)
                }
                
                // Process speech recognition
                let res = self.recognizeData(buffer: buffer)
                
                if let resultString = res.result {
                    DispatchQueue.main.async {
                        do {
                            if let resultData = resultString.data(using: .utf8),
                               let parsedResult = try? JSONDecoder().decode(VoskResult.self, from: resultData) {
                                
                                if res.completed && self.hasListener {
                                    // Send detailed result with timestamps if available
                                    if let wordResults = parsedResult.result {
                                        if let resultWithTimestamps = try? JSONEncoder().encode(wordResults),
                                           let resultString = String(data: resultWithTimestamps, encoding: .utf8) {
                                            self.sendEvent(withName: "onResult", body: resultString)
                                            self.sendEvent(withName: "onFinalResult", body: resultString)
                                        } else {
                                            self.sendEvent(withName: "onResult", body: parsedResult.text ?? "")
                                            self.sendEvent(withName: "onFinalResult", body: parsedResult.text ?? "")
                                        }
                                    } else {
                                        self.sendEvent(withName: "onResult", body: parsedResult.text ?? "")
                                        self.sendEvent(withName: "onFinalResult", body: parsedResult.text ?? "")
                                    }
                                } else if !res.completed && self.hasListener {
                                    // Check if partial result is different from last one
                                    if self.lastRecognizedResult == nil || 
                                       self.lastRecognizedResult!.partial != parsedResult.partial && 
                                       !(parsedResult.partial?.isEmpty ?? true) {
                                        self.sendEvent(withName: "onPartialResult", body: parsedResult.partial ?? "")
                                    }
                                }
                                self.lastRecognizedResult = parsedResult
                            }
                        } catch {
                            print("Error processing recognition result: \(error)")
                        }
                    }
                }
            }
        }
    }
    
    /// Calculate and send volume updates (throttled)
    private func calculateAndSendVolume(buffer: AVAudioPCMBuffer) {
        let now = Date()
        if now.timeIntervalSince(lastVolumeUpdateTime) < volumeUpdateInterval {
            return // Throttle updates
        }
        
        lastVolumeUpdateTime = now
        
        // Calculate RMS (root mean square) to get volume level
        var sum: Float = 0.0
        let frameLength = Int(buffer.frameLength)
        
        if let channelData = buffer.int16ChannelData?[0] {
            for i in 0..<frameLength {
                let sample = Float(channelData[i]) / Float(Int16.max)
                sum += sample * sample
            }
            
            if frameLength > 0 {
                let rms = sqrt(sum / Float(frameLength))
                let volume = max(-60, min(0, 20 * log10(max(0.0001, rms)))) // Convert to dB (range -60 to 0)
                let normalizedVolume = (volume + 60) / 60 // Normalize to 0-1 range
                
                // Send event on main thread
                DispatchQueue.main.async {
                    if self.hasListener {
                        self.sendEvent(withName: "onVolumeChanged", body: normalizedVolume)
                    }
                }
            }
        }
    }

    /// Unload speech recognition and model
    @objc(unload) func unload() -> Void {
        stopInternal(withoutEvents: false)
    }

    /// Stop speech recognition if started
    @objc(stop) func stop() -> Void {
        // stop engines and send onFinalResult event
        stopInternal(withoutEvents: false)
    }
    
    /// Pause speech recognition
    @objc(pause)
    func pause() -> Void {
        if !isPaused && audioEngine.isRunning {
            isPaused = true
        }
    }
    
    /// Resume speech recognition
    @objc(resume:withRejecter:)
    func resume(resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) -> Void {
        if isPaused && audioEngine.isRunning {
            isPaused = false
            resolve(true)
        } else {
            resolve(false)
        }
    }

    /// Do internal cleanup on stop recognition
    func stopInternal(withoutEvents: Bool) {
        // Remove audio tap
        if audioEngine.isRunning {
            inputNode.removeTap(onBus: 0)
            audioEngine.stop()
            
            // Send final result if needed
            if hasListener && !withoutEvents {
                if let result = lastRecognizedResult {
                    if let wordResults = result.result {
                        do {
                            let resultWithTimestamps = try JSONEncoder().encode(wordResults)
                            if let resultString = String(data: resultWithTimestamps, encoding: .utf8) {
                                self.sendEvent(withName: "onFinalResult", body: resultString)
                            }
                        } catch {
                            self.sendEvent(withName: "onFinalResult", body: result.text ?? result.partial ?? "")
                        }
                    } else {
                        self.sendEvent(withName: "onFinalResult", body: result.text ?? result.partial ?? "")
                    }
                }
            }
            lastRecognizedResult = nil
        }
        
        if let writer = wavWriter {
            // Use a local variable and clear the instance variable first
            // to prevent any chance of double-finalization
            let localWriter = writer
            wavWriter = nil
            
            // Finalize on the processing queue to avoid thread contention
            processingQueue.async {
                localWriter.finalize()
                print("Audio file finalized and saved")
            }
        }
        // Close audio file if open
        audioFile = nil
        
        // Free recognizer
        if recognizer != nil {
            vosk_recognizer_free(recognizer)
            recognizer = nil
        }
        
        // Cancel timeout timer
        if timeoutTimer != nil {
            timeoutTimer?.invalidate()
            timeoutTimer = nil
        }

        // Reset audio session
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            print("Error deactivating audio session: \(error)")
        }
    }

    /// Process the audio buffer and do recognition with Vosk
    func recognizeData(buffer: AVAudioPCMBuffer) -> (result: String?, completed: Bool) {
        guard let recognizer = recognizer, buffer.format.channelCount > 0 else {
            return (nil, false)
        }
        
        let dataLen = Int(buffer.frameLength * 2)
        let channels = UnsafeBufferPointer(start: buffer.int16ChannelData, count: 1)
        
        let endOfSpeech = channels[0].withMemoryRebound(to: Int8.self, capacity: dataLen) {
            return vosk_recognizer_accept_waveform(recognizer, $0, Int32(dataLen))
        }
        
        let result: String?
        if endOfSpeech == 1 {
            result = String(validatingUTF8: vosk_recognizer_result(recognizer))
        } else {
            result = String(validatingUTF8: vosk_recognizer_partial_result(recognizer))
        }
        
        return (result, endOfSpeech == 1)
    }
}

// First, add the WavWriter class to Vosk.swift (you can place this at end of file)
fileprivate struct WAVHeader {
    // "RIFF"
    var chunkID: (UInt8, UInt8, UInt8, UInt8) = (0x52, 0x49, 0x46, 0x46)  // 'R','I','F','F'
    // Chunk Size: 4 bytes (filled in at finalize)
    var chunkSize: UInt32 = 36
    // "WAVE"
    var format: (UInt8, UInt8, UInt8, UInt8) = (0x57, 0x41, 0x56, 0x45)   // 'W','A','V','E'

    // "fmt "
    var subchunk1ID: (UInt8, UInt8, UInt8, UInt8) = (0x66, 0x6D, 0x74, 0x20) // 'f','m','t',' '
    // Subchunk1Size = 16 for PCM
    var subchunk1Size: UInt32 = 16
    // AudioFormat = 1 for PCM
    var audioFormat: UInt16 = 1
    // NumChannels
    var numChannels: UInt16 = 1
    // SampleRate
    var sampleRate: UInt32 = 16000
    // ByteRate = SampleRate * NumChannels * BitsPerSample/8
    var byteRate: UInt32 = 32000
    // BlockAlign = NumChannels * BitsPerSample/8
    var blockAlign: UInt16 = 2
    // BitsPerSample
    var bitsPerSample: UInt16 = 16

    // "data"
    var subchunk2ID: (UInt8, UInt8, UInt8, UInt8) = (0x64, 0x61, 0x74, 0x61) // 'd','a','t','a'
    // Subchunk2Size: 4 bytes (filled in at finalize)
    var subchunk2Size: UInt32 = 0

    func toData() -> Data {
        var data = Data()
        // chunkID
        data.append([chunkID.0, chunkID.1, chunkID.2, chunkID.3], count: 4)
        // chunkSize (little endian)
        var chunkSizeLE = chunkSize.littleEndian
        data.append(Data(bytes: &chunkSizeLE, count: 4))
        // format
        data.append([format.0, format.1, format.2, format.3], count: 4)
        // subchunk1ID
        data.append([subchunk1ID.0, subchunk1ID.1, subchunk1ID.2, subchunk1ID.3], count: 4)
        // subchunk1Size
        var sc1SizeLE = subchunk1Size.littleEndian
        data.append(Data(bytes: &sc1SizeLE, count: 4))
        // audioFormat
        var audioFormatLE = audioFormat.littleEndian
        data.append(Data(bytes: &audioFormatLE, count: 2))
        // numChannels
        var numChannelsLE = numChannels.littleEndian
        data.append(Data(bytes: &numChannelsLE, count: 2))
        // sampleRate
        var sampleRateLE = sampleRate.littleEndian
        data.append(Data(bytes: &sampleRateLE, count: 4))
        // byteRate
        var byteRateLE = byteRate.littleEndian
        data.append(Data(bytes: &byteRateLE, count: 4))
        // blockAlign
        var blockAlignLE = blockAlign.littleEndian
        data.append(Data(bytes: &blockAlignLE, count: 2))
        // bitsPerSample
        var bpsLE = bitsPerSample.littleEndian
        data.append(Data(bytes: &bpsLE, count: 2))
        // subchunk2ID
        data.append([subchunk2ID.0, subchunk2ID.1, subchunk2ID.2, subchunk2ID.3], count: 4)
        // subchunk2Size
        var sc2SizeLE = subchunk2Size.littleEndian
        data.append(Data(bytes: &sc2SizeLE, count: 4))

        return data
    }
}

fileprivate class WavWriter {
    private var fileHandle: FileHandle?
    private var header = WAVHeader()
    private var filePath: URL
    private var isOpen = false
    private var totalSamplesWritten: UInt32 = 0

    init?(filePath: String, sampleRate: Int, numChannels: Int, bitsPerSample: Int) {
        let cleanPath = filePath.replacingOccurrences(of: "file://", with: "")
        self.filePath = URL(fileURLWithPath: cleanPath)

        // Create directory if it doesn't exist
        let directory = self.filePath.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            print("WavWriter: Failed to create directory: \(error.localizedDescription)")
            return nil
        }

        // Populate the header's fields
        header.numChannels = UInt16(numChannels)
        header.sampleRate = UInt32(sampleRate)
        header.bitsPerSample = UInt16(bitsPerSample)
        header.byteRate = UInt32(sampleRate * numChannels * (bitsPerSample / 8))
        header.blockAlign = UInt16(numChannels * (bitsPerSample / 8))

        // Attempt to open the file for writing
        FileManager.default.createFile(atPath: self.filePath.path, contents: nil, attributes: nil)
        do {
            fileHandle = try FileHandle(forWritingTo: self.filePath)
        } catch {
            print("WavWriter: Failed to open file handle: \(error.localizedDescription)")
            return nil
        }

        // Write a placeholder 44-byte header
        if let fh = fileHandle {
            let headerData = header.toData()
            fh.write(headerData)
            isOpen = true
            print("WavWriter: Initialized WAV file at \(self.filePath.path)")
        }
    }

    func appendSamples(_ samples: UnsafePointer<Int16>, sampleCount: Int) {
        guard isOpen, let fh = fileHandle, sampleCount > 0 else {
            return
        }

        // Convert pointer to Data
        let bytesToWrite = sampleCount * MemoryLayout<Int16>.size
        guard bytesToWrite > 0 else { return }
        
        let data = Data(bytes: samples, count: bytesToWrite)

        // Write
        fh.write(data)
        totalSamplesWritten += UInt32(sampleCount)
    }

    func finalize() {
        guard isOpen, let fh = fileHandle else { return }

        // Calculate sizes
        let bitsPerSample = UInt32(header.bitsPerSample)
        let numChannels = UInt32(header.numChannels)
        let bytesPerFrame = (bitsPerSample / 8) * numChannels
        let dataSize = totalSamplesWritten * bytesPerFrame
        let chunkSize = 36 + dataSize

        // Flush any pending writes
        fh.synchronizeFile()

        // Seek to chunkSize offset (4) to write updated value
        fh.seek(toFileOffset: 4)
        var chunkSizeLE = chunkSize.littleEndian
        fh.write(Data(bytes: &chunkSizeLE, count: 4))

        // Seek to subchunk2Size offset (40) to write updated value
        fh.seek(toFileOffset: 40)
        var dataSizeLE = dataSize.littleEndian
        fh.write(Data(bytes: &dataSizeLE, count: 4))

        // Close
        fh.closeFile()
        isOpen = false

        print("WavWriter: Finalized WAV. DataSize=\(dataSize), chunkSize=\(chunkSize), totalSamples=\(totalSamplesWritten)")
    }
}