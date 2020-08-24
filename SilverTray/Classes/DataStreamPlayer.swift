//
//  DataStreamPlayer.swift
//  SilverTray
//
//  Created by DCs-OfficeMBP on 24/01/2019.
//  Copyright (c) 2020 SK Telecom Co., Ltd. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

import Foundation
import AVFoundation
import os.log

import SilverTray.ObjcExceptionCatcher

/**
 Player for data chunks
 */
public class DataStreamPlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    
    #if !os(watchOS)
    private let speedController = AVAudioUnitVarispeed()
    private let pitchController = AVAudioUnitTimePitch()
    #endif
    
    private let audioFormat: AVAudioFormat
    private let jitterBufferSize = 2 // Use 2 chunks as a jitter buffer
    private lazy var chunkSize = Int(audioFormat.sampleRate / 10) // 100ms
    
    /// To notify last audio buffer is consumed.
    private var lastBuffer: AVAudioPCMBuffer?
    
    /// Index of buffer to be scheduled
    private var curBufferIndex = 0
    
    /// If samples which is not enough to make chunk appended, It should be stored tempAudioArray and wait for other samples.
    private var tempAudioArray = [Float]()

    /// hold entire audio buffers for seek function.
    private var audioBuffers = [AVAudioPCMBuffer]() {
        didSet {
            if oldValue.count < audioBuffers.count {
                NotificationCenter.default.post(name: .audioBufferChange, object: nil, userInfo: nil)
            }
        }
    }
    
    private var audioQueue = DispatchQueue(label: "com.sktelecom.silver_tray.audio")
    
    #if DEBUG
    private var appendedData = Data()
    private var consumedData = Data()
    #endif

    public let decoder: AudioDecodable
    public weak var delegate: DataStreamPlayerDelegate?
    private var isPaused = false {
        didSet {
            if oldValue != isPaused {
                os_log("paused: %@", log: .player, type: .debug, "\(isPaused)")
            }
        }
    }
    
    /// current state
    public var state: DataStreamPlayerState = .idle {
        didSet {
            if oldValue != state {
                os_log("state changed: %@", log: .player, type: .debug, "\(state)")
                delegate?.dataStreamPlayerStateDidChange(state)
            }
        }
    }
    
    /// current time
    public var offset: Int {
        return Int((Double(chunkSize * curBufferIndex) / audioFormat.sampleRate) * 1000)
    }
    
    /// duration
    public var duration: Int {
        return Int((Double(chunkSize * audioBuffers.count) / audioFormat.sampleRate) * 1000)
    }
    
    public var volume: Float {
        get {
            return player.volume
        }
        set {
            player.volume = newValue
        }
    }
    
    #if !os(watchOS)
    public var speed: Float {
        get {
            return speedController.rate
        }
        
        set {
            speedController.rate = newValue
        }
    }
    
    public var pitch: Float {
        get {
            return pitchController.pitch
        }
        
        set {
            pitchController.pitch = newValue
        }
    }
    #endif
    
    /**
     Initialize `DataStreamPlayer`.

     - If you use the same format of decoder, You can use `init(decoder: AudioDecodable)`
     */
    public init(decoder: AudioDecodable, audioFormat: AVAudioFormat) throws {
        self.audioFormat = audioFormat
        self.decoder = decoder
        
        if let error = ObjcExceptionCatcher.objcTry({ () -> Error? in
            // Attach nodes
            engine.attach(player)
            
            #if !os(watchOS)
            engine.attach(speedController)
            engine.attach(pitchController)
            #endif
            
            do {
                try initEngine()
            } catch {
                return error
            }
            
            return nil
        }) {
            os_log("init engine error: %@", log: .audioEngine, type: .error, "\(error)")
            throw error
        }
    }
    
    /**
     Initialize without `AVAudioFormat`
     
     AVAudioFormat follows decoder's format will be created automatically.
     */
    public convenience init(decoder: AudioDecodable) throws {
        guard let audioFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                              sampleRate: decoder.sampleRate,
                                              channels: AVAudioChannelCount(decoder.channels),
                                              interleaved: false) else {
                                                throw DataStreamPlayerError.unsupportedAudioFormat
        }
        
        try self.init(decoder: decoder, audioFormat: audioFormat)
    }
    
    deinit {
        internalStop()
    }
    
    private func connectAudioChain() {
        if let error = (ObjcExceptionCatcher.objcTry { () -> Error? in
            #if os(watchOS)
            engine.connect(player, to: engine.mainMixerNode, format: audioFormat)
            #else
            // To control speed, Put speedController into the chain
            // Pitch controller has rate too. But if you adjust it without pitch value, you will get unexpected audio rate.
            engine.connect(player, to: speedController, format: audioFormat)
            
            // To control pitch, Put pitchController into the chain
            engine.connect(speedController, to: pitchController, format: audioFormat)
            
            // To control volume, Last of chain must me mixer node.
            engine.connect(pitchController, to: engine.mainMixerNode, format: audioFormat)
            #endif
            
            return nil
        }) {
            os_log("connection failed: %@", log: .audioEngine, type: .error, "\(error)")
        }
    }
    
    private func disconnectAudioChain() {
        if let error = ObjcExceptionCatcher.objcTry({ () -> Error? in
            #if !os(watchOS)
            engine.disconnectNodeOutput(pitchController)
            engine.disconnectNodeOutput(speedController)
            #endif
            
            engine.disconnectNodeOutput(player)
            
            return nil
        }) {
            os_log("disconnection failed: %@", log: .audioEngine, type: .error, "\(error)")
        }
    }
    
    public var isPlaying: Bool {
        return player.isPlaying
    }
    
    /**
     Play audio data.
     - You can call this method anytime you want. (this player doesn't care whether entire audio data was appened or not)
     */
    public func play() {
        os_log("try to play data stream", log: .player, type: .debug)
        
        audioQueue.async { [weak self] in
            guard let self = self else { return }
            
            do {
                try self.initEngine()
            } catch {
                os_log("engine init failed: %@", log: .audioEngine, type: .error, "\(error)")
                self.state = .error(error)
                return
            }
            
            if let objcException = (ObjcExceptionCatcher.objcTry {
                os_log("try to start player", log: .audioEngine, type: .debug)
                self.player.play()
                self.isPaused = false
                self.state = .start
                os_log("player started", log: .audioEngine, type: .debug)
                
                return nil
            }) {
                os_log("player start failed: %@", log: .audioEngine, type: .error, "\(objcException)")
                self.printAudioLogs()
                self.state = .error(objcException)
                return
            }
            
            // if audio session is changed and influence AVAudioEngine, we should handle this.
            NotificationCenter.default.removeObserver(self, name: .AVAudioEngineConfigurationChange, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(self.engineConfigurationChange), name: .AVAudioEngineConfigurationChange, object: nil)
        }
    }
    
    public func pause() {
        os_log("try to pause", log: .audioEngine, type: .debug)
        
        audioQueue.async { [weak self] in
            self?.player.pause()
            self?.isPaused = true
            self?.state = .pause
        }
    }
    
    public func resume() {
        play()
    }
    
    public func stop() {
        os_log("try to stop", log: .audioEngine, type: .debug)
        
        // To avoid simultanious audio engine control, remove observer hear.
        NotificationCenter.default.removeObserver(self, name: .AVAudioEngineConfigurationChange, object: nil)
        NotificationCenter.default.removeObserver(self, name: .audioBufferChange, object: self)
        
        audioQueue.async { [weak self] in
            self?.internalStop()
            self?.state = .stop
        }
    }
    
    /**
     Stop AVAudioPlayerNode.

     It stops player only. Because Stopping AVAudioEngine can occur the exception within simultanious use case.
     AVAudioEngine will be released by ARC
     (This is the weak point of AVAudioEngine)
     */
    func internalStop() {
        player.stop()
        isPaused = false
        lastBuffer = nil
        curBufferIndex = 0
        tempAudioArray.removeAll()
        audioBuffers.removeAll()
        
        #if DEBUG
        let appendedFilename = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("silver_tray_appended.encoded")
        let consumedFilename = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("silver_tray_consumed.raw")
        do {
            // write consumedData to file
            try self.appendedData.write(to: appendedFilename)
            try self.consumedData.write(to: consumedFilename)
            
            os_log("appended data to file: %@", log: .player, type: .debug, "\(appendedFilename)")
            os_log("consumed data to file: %@", log: .player, type: .debug, "\(consumedFilename)")
        } catch {
            os_log("file write failed: %@", log: .player, type: .error, "\(error)")
        }
        
        appendedData.removeAll()
        consumedData.removeAll()
        #endif
    }
    
    /**
     seek
     - parameter to: seek time (millisecond)
     */
    public func seek(to offset: Int, completion: ((Result<Void, Error>) -> Void)?) {
        os_log("try to seek: %@", log: .player, type: .debug, "\(offset)")

        audioQueue.async { [weak self] in
            guard let self = self else { return }
            
            guard (0..<self.duration).contains(offset) else {
                completion?(.failure(DataStreamPlayerError.seekRangeExceed))
                return
            }
            
            let chunkTime = Int((Float(self.chunkSize) / Float(self.audioFormat.sampleRate)) * 1000)
            self.curBufferIndex = offset / chunkTime
            completion?(.success(()))
        }
    }
}

// MARK: append data

extension DataStreamPlayer {
    /**
     This function should be called If you append last data.
     - Though player has less amount of samples than chunk size, But player will play it when this api is called.
     - Player can calculate duration of TTS.
     */
    public func lastDataAppended() throws {
        os_log("Last data appended. No data can be appended any longer.", log: .player, type: .debug)

        try audioQueue.sync {
            guard lastBuffer == nil else {
                throw DataStreamPlayerError.audioBufferClosed
            }

            if 0 < tempAudioArray.count, let lastPcmData = tempAudioArray.pcmBuffer(format: audioFormat) {
                os_log("Temp audio data will be scheduled. Because it is last data.", log: .player, type: .debug)
                audioBuffers.append(lastPcmData)
            }
            
            lastBuffer = audioBuffers.last
            tempAudioArray.removeAll()
            
            guard 0 < audioBuffers.count else {
                os_log("No data appended.", log: .player, type: .info)
                finish()
                return
            }
            
            // last data received but recursive scheduler is not started yet.
            if curBufferIndex == 0 {
                curBufferIndex += (audioBuffers.count - 1)
                for audioBuffer in audioBuffers {
                    scheduleBuffer(audioBuffer: audioBuffer)
                }
            }
            
            os_log("duration: %@", log: .player, type: .debug, "\(duration)")
        }
    }
    
    /**
     Player keeps All data for calculating offset and offering seek-function
     The data appended must be separated to suitable chunk size (200ms)
     - parameter data: the data to be decoded and played.
     */
    public func appendData(_ data: Data) throws {
        try audioQueue.sync {
            guard lastBuffer == nil else {
                throw DataStreamPlayerError.audioBufferClosed
            }
            
            #if DEBUG
            appendedData.append(data)
            #endif
            
            let pcmData: [Float]
            do {
                pcmData = try decoder.decode(data: data)
            } catch {
                os_log("Decode failed", log: .decoder, type: .error)
                state = .error(error)
                return
            }

            // Lasting audio data has to be added to schedule it.
            var audioDataArray = [Float]()
            if 0 < tempAudioArray.count {
                audioDataArray.append(contentsOf: tempAudioArray)
//                log.debug("temp audio processing: \(self.tempAudioArray.count)")
                tempAudioArray.removeAll()
            }
            audioDataArray.append(contentsOf: pcmData)
            
            var bufferPosition = 0
            var pcmBufferArray = [AVAudioPCMBuffer]()
            while bufferPosition < audioDataArray.count {
                // If it's not a last data but smaller than chunk size, Put it into the tempAudioArray for future processing
                guard bufferPosition + chunkSize < audioDataArray.count else {
                    tempAudioArray.append(contentsOf: audioDataArray[bufferPosition..<audioDataArray.count])
//                    log.debug("tempAudio size: \(self.tempAudioArray.count), chunkSize: \(self.chunkSize)")
                    break
                }
                
                // Though the data is smaller than chunk, But it has to be scheduled.
                let bufferSize = min(chunkSize, audioDataArray.count - bufferPosition)
                let chunk = Array(audioDataArray[bufferPosition..<(bufferPosition + bufferSize)])
                guard let pcmBuffer = chunk.pcmBuffer(format: audioFormat) else {
                    continue
                }
                
                pcmBufferArray.append(pcmBuffer)
                bufferPosition += bufferSize
            }
            
            if 0 < pcmBufferArray.count {
                audioBuffers.append(contentsOf: pcmBufferArray)
                prepareBuffer()
            }
        }
    }

    /**
     To get data from file or remote repository.
     - You are not supposed to use this method on MainThread for getting data using network
     */
    func setSource(url: String) throws {
        guard lastBuffer != nil else { throw DataStreamPlayerError.audioBufferClosed }
        guard let resourceURL = URL(string: url) else { throw DataStreamPlayerError.unavailableSource }
        
        let resourceData = try Data(contentsOf: resourceURL)
        try appendData(resourceData)
    }
}

// MARK: private functions
private extension DataStreamPlayer {
    func initEngine() throws {
        guard self.engine.isRunning == false else { return }
        
        if let objcException = (ObjcExceptionCatcher.objcTry {
            do {
                // for the sound effects
                connectAudioChain()
                
                // start audio engine
                try engine.start()
                
                os_log("engine started", log: .audioEngine, type: .debug)
            } catch {
                return error
            }
            
            return nil
        }) {
            throw objcException
        }
    }
    
    /**
     DataStreamPlayer has jitter buffers to play stably.
     First of all, schedule jitter size of Buffers at ones.
     When the buffer of index(N)  consumed, buffer of index(N+jitterSize) will be scheduled.
     - seealso: scheduleBuffer()
     */
    func prepareBuffer() {
        guard curBufferIndex == 0, jitterBufferSize < audioBuffers.count else { return }
        
        // schedule audio buffers to play
        for bufferIndex in 0..<jitterBufferSize {
            if let audioBuffer = audioBuffers[safe: bufferIndex] {
                curBufferIndex = bufferIndex
                scheduleBuffer(audioBuffer: audioBuffer)
            }
        }
    }
    
    /// schedule buffer and check last data was consumed on it's closure.
    func scheduleBuffer(audioBuffer: AVAudioPCMBuffer) {
        let bufferHandler: AVAudioNodeCompletionHandler = { [weak self] in
            self?.audioQueue.async { [weak self] in
                guard let self = self else { return }
                
                #if DEBUG
                if let channelData = audioBuffer.floatChannelData?.pointee {
                    let consumedData = Data(bytes: channelData, count: Int(audioBuffer.frameLength)*4)
                    self.consumedData.append(consumedData)
                }
                #endif
                
                // Though player was already stopped. But closure is called
                // This situation will be occured often. Because retrieving audio data from DSP is very hard
                guard [.start, .pause, .resume].contains(self.state) else { return }
                
                // If player consumed last buffer
                guard audioBuffer != self.lastBuffer else {
                    self.finish()
                    return
                }
                
                guard let nextBuffer = self.audioBuffers[safe: self.curBufferIndex] else {
                    guard self.lastBuffer == nil else { return }
                    os_log("waiting for next audio data.", log: .player, type: .debug)
                    
                    NotificationCenter.default.addObserver(forName: .audioBufferChange, object: self, queue: nil) { [weak self] (notification) in
                        guard let self = self else { return }
                        guard let nextBuffer = self.audioBuffers[safe: self.curBufferIndex] else { return }
                        
                        os_log("Try to restart scheduler.", log: .player, type: .debug)
                        self.scheduleBuffer(audioBuffer: nextBuffer)
                        
                        NotificationCenter.default.removeObserver(self, name: .audioBufferChange, object: self)
                    }
                    return
                }
                
                self.scheduleBuffer(audioBuffer: nextBuffer)
            }
        }

        if let error = ObjcExceptionCatcher.objcTry({ () -> Error? in
            player.scheduleBuffer(audioBuffer, completionHandler: bufferHandler)
            curBufferIndex += 1
            return nil
        }) {
            os_log("data schedule error: %@", log: .audioEngine, type: .error, "\(error)")
            printAudioLogs(requestBuffer: audioBuffer)
        }
    }
    
    func finish() {
        NotificationCenter.default.removeObserver(self, name: .AVAudioEngineConfigurationChange, object: nil)
        NotificationCenter.default.removeObserver(self, name: .audioBufferChange, object: self)
        
        internalStop()
        state = .finish
    }
    
    func printAudioLogs(requestBuffer: AVAudioPCMBuffer? = nil) {
        os_log("audio state:\n\t\trequested format: %@\n\t\tplayer format: %@\n\t\tengine format: %@",
               log: .audioEngine, type: .info,
               String(describing: requestBuffer?.format), "\(player.outputFormat(forBus: 0))", "\(engine.inputNode.outputFormat(forBus: 0))")
        
        #if !os(macOS)
        os_log("\n\t\t%@\n\t\t%@\n\t\taudio session sampleRate: %@",
               log: .audioEngine, type: .info,
               "\(AVAudioSession.sharedInstance().category)", "\(AVAudioSession.sharedInstance().categoryOptions)", "\(AVAudioSession.sharedInstance().sampleRate)")
        #endif
    }
}


@objc private extension DataStreamPlayer {
    func engineConfigurationChange(notification: Notification) {
        os_log("player will be paused by changed engine configuration: \n", log: .audioEngine, type: .debug)
        
        audioQueue.async { [weak self] in
            os_log("reconnect audio chain", log: .audioEngine, type: .debug)
            // Reconnect audio chain
            self?.disconnectAudioChain()
            self?.connectAudioChain()
            
            // We can insist that audio should be resume. If pause() method is not called explicitly.
            if self?.isPaused == false {
                os_log("resume audio", log: .audioEngine, type: .debug)
                self?.play()
            }
        }
    }
}

// MARK: - Array + AVAudioPCMBuffer

private extension Array where Element == Float {
    func pcmBuffer(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(count)) else { return nil }
        pcmBuffer.frameLength = pcmBuffer.frameCapacity
        
        if let ptrChannelData = pcmBuffer.floatChannelData?.pointee {
            ptrChannelData.assign(from: self, count: count)
        }
        
        return pcmBuffer
    }
}

// MARK: - Notification

private extension Notification.Name {
    static let audioBufferChange = Notification.Name(rawValue: "com.sktelecom.silver_tray.audio_buffer")
}
