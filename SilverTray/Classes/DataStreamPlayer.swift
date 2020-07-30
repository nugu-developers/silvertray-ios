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
    public var isPaused = false {
        didSet {
            log.debug("paused: \(isPaused)")
        }
    }
    
    /// current state
    public var state: DataStreamPlayerState = .idle {
        didSet {
            if oldValue != state {
                log.debug("state changed: \(state)")
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
    
    public var isPlaying: Bool {
        return player.isPlaying
    }
    
    public var volume: Float {
        get {
            return player.volume
        }
        set {
            audioQueue.async { [weak self] in
                self?.player.volume = newValue
            }
        }
    }
    
    #if !os(watchOS)
    public var speed: Float {
        get {
            return speedController.rate
        }
        
        set {
            audioQueue.async { [weak self] in
                self?.speedController.rate = newValue
            }
        }
    }
    
    public var pitch: Float {
        get {
            return pitchController.pitch
        }
        
        set {
            audioQueue.async { [weak self] in
                self?.pitchController.pitch = newValue
            }
        }
    }
    #endif
    
    /**
     Initialize `DataStreamPlayer`.
     
     - If you use the same format of decoder, You can use `init(decoder: AudioDecodable)`
     */
    public init(decoder: AudioDecodable, audioFormat: AVAudioFormat) {
        self.audioFormat = audioFormat
        self.decoder = decoder
        
        audioQueue.async { [weak self] in
            guard let self = self else { return }
            
            if let error = (ObjcExceptionCatcher.objcTry { () -> Error? in
                // Attach nodes
                self.engine.attach(self.player)
                
                #if !os(watchOS)
                self.engine.attach(self.speedController)
                self.engine.attach(self.pitchController)
                #endif
                
                // Connect nodes for the sound effects
                #if os(watchOS)
                self.engine.connect(player, to: engine.mainMixerNode, format: audioFormat)
                #else
                // To control speed, Put speedController into the chain
                // Pitch controller has rate too. But if you adjust it without pitch value, you will get unexpected audio rate.
                self.engine.connect(self.player, to: self.speedController, format: self.audioFormat)
                
                // To control pitch, Put pitchController into the chain
                self.engine.connect(self.speedController, to: self.pitchController, format: self.audioFormat)
                
                // To control volume, Last of chain must me mixer node.
                self.engine.connect(self.pitchController, to: self.engine.mainMixerNode, format: self.audioFormat)
                #endif
                
                // Prepare AudioEngine
                self.engine.prepare()
                
                return nil
            }) {
                log.error("error: \(error)")
                self.state = .error(error)
            }
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
        
        self.init(decoder: decoder, audioFormat: audioFormat)
    }
    
    /**
     Play audio data.
     - You can call this method anytime you want. (this player doesn't care whether entire audio data was appened or not)
     */
    public func play() {
        log.debug("try to play data stream")
        
        audioQueue.async { [weak self] in
            guard let self = self else { return }
            
            do {
                try self.engineInit()
            } catch {
                log.error("engine init failed: \(error)")
                self.state = .error(error)
                return
            }
            
            if let objcException = (ObjcExceptionCatcher.objcTry {
                log.debug("try to start player")
                self.player.play()
                self.isPaused = false
                self.state = .start
                log.debug("player started")
                
                return nil
            }) {
                log.error("cannot play, error: \(objcException)")
                self.internalStop(notify: false)
                self.state = .error(objcException)
                return
            }
            
            // if audio session is changed and influence AVAudioEngine, we should handle this.
            NotificationCenter.default.removeObserver(self, name: .AVAudioEngineConfigurationChange, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(self.engineConfigurationChange), name: .AVAudioEngineConfigurationChange, object: nil)
        }
    }
    
    public func pause() {
        log.debug("try to pause")
        
        audioQueue.async { [weak self] in
            guard let self = self else { return }
            
            self.player.pause()
            self.isPaused = true
            self.state = .pause
            
            log.debug("DataStreamPlayer is pauesed")
        }
    }
    
    public func resume() {
        play()
    }
    
    public func stop() {
        log.debug("try to stop")
        
        audioQueue.async { [weak self] in
            self?.internalStop(notify: true)
        }
    }
    
    /**
     Notification must removed before engine stopped.
     Or you may face to exception from inside of AVAudioEngine.
     - ex) AVAudioSession is changed when the audio engine is stopped. but this notification is not removed yet.
     */
    private func internalStop(notify: Bool) {
        log.debug("try to reset")
        
        NotificationCenter.default.removeObserver(self, name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: .AVAudioEngineConfigurationChange, object: nil)
        NotificationCenter.default.removeObserver(self, name: .audioBufferChange, object: self)
        
        if let error = ObjcExceptionCatcher.objcTry ({ () -> Error? in
            // Stop player node
            player.stop()
            
            // Disconnect nodes
            engine.disconnectNodeOutput(pitchController)
            engine.disconnectNodeInput(pitchController)
            engine.disconnectNodeOutput(speedController)
            engine.disconnectNodeInput(speedController)
            engine.disconnectNodeOutput(player)
            engine.disconnectNodeOutput(player)
            
            // Stop engine
            engine.stop()
            
            return nil
        }) {
            log.error("reset error: \(error)")
        }
        
        // Reset properties
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
            try appendedData.write(to: appendedFilename)
            try consumedData.write(to: consumedFilename)
            
            log.debug("appended data to file :\(appendedFilename)")
            log.debug("consumed data to file :\(consumedFilename)")
        } catch {
            log.debug(error)
        }
        
        appendedData.removeAll()
        consumedData.removeAll()
        #endif
        
        state = .stop
    }
    
    /**
     seek
     - parameter to: seek time (millisecond)
     */
    public func seek(to offset: Int, completion: ((Result<Void, Error>) -> Void)?) {
        log.debug("try to seek")
        
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
    public func lastDataAppended() {
        log.debug("Last data appended. No data can be appended any longer.")
        
        audioQueue.async { [weak self] in
            guard let self = self else { return }
            
            guard self.lastBuffer == nil else {
                log.error("error: \(DataStreamPlayerError.audioBufferClosed)")
                self.internalStop(notify: false)
                self.state = .error(DataStreamPlayerError.audioBufferClosed)
                return
            }
            
            if 0 < self.tempAudioArray.count, let lastPcmData = self.tempAudioArray.pcmBuffer(format: self.audioFormat) {
                log.debug("Temp audio data will be scheduled. Because it is last data.")
                self.audioBuffers.append(lastPcmData)
            }
            
            self.lastBuffer = self.audioBuffers.last
            self.tempAudioArray.removeAll()
            
            guard 0 < self.audioBuffers.count else {
                log.info("No data appended.")
                self.internalStop(notify: false)
                self.state = .finish
                return
            }
            
            // last data received but recursive scheduler is not started yet.
            if self.curBufferIndex == 0 {
                self.curBufferIndex += (self.audioBuffers.count - 1)
                for audioBuffer in self.audioBuffers {
                    self.scheduleBuffer(audioBuffer: audioBuffer)
                }
            }
            
            log.debug("duration: \(self.duration)")
        }
    }
    
    /**
     Player keeps All data for calculating offset and offering seek-function
     The data appended must be separated to suitable chunk size (200ms)
     - parameter data: the data to be decoded and played.
     */
    public func appendData(_ data: Data) {
        audioQueue.async { [weak self] in
            guard let self = self else { return }
            
            guard self.lastBuffer == nil else {
                log.error("error: \(DataStreamPlayerError.audioBufferClosed)")
                self.internalStop(notify: false)
                self.state = .error(DataStreamPlayerError.audioBufferClosed)
                return
            }
            
            #if DEBUG
            self.appendedData.append(data)
            #endif
            
            let pcmData: [Float]
            do {
                pcmData = try self.decoder.decode(data: data)
            } catch {
                log.error("Decode fail error: \(error)")
                self.internalStop(notify: false)
                self.state = .error(error)
                return
            }
            
            // Lasting audio data has to be added to schedule it.
            var audioDataArray = [Float]()
            if 0 < self.tempAudioArray.count {
                audioDataArray.append(contentsOf: self.tempAudioArray)
                //                log.debug("temp audio processing: \(self.tempAudioArray.count)")
                self.tempAudioArray.removeAll()
            }
            audioDataArray.append(contentsOf: pcmData)
            
            var bufferPosition = 0
            var pcmBufferArray = [AVAudioPCMBuffer]()
            while bufferPosition < audioDataArray.count {
                // If it's not a last data but smaller than chunk size, Put it into the tempAudioArray for future processing
                guard bufferPosition + self.chunkSize < audioDataArray.count else {
                    self.tempAudioArray.append(contentsOf: audioDataArray[bufferPosition..<audioDataArray.count])
                    //                    log.debug("tempAudio size: \(self.tempAudioArray.count), chunkSize: \(self.chunkSize)")
                    break
                }
                
                // Though the data is smaller than chunk, But it has to be scheduled.
                let bufferSize = min(self.chunkSize, audioDataArray.count - bufferPosition)
                let chunk = Array(audioDataArray[bufferPosition..<(bufferPosition + bufferSize)])
                guard let pcmBuffer = chunk.pcmBuffer(format: self.audioFormat) else {
                    continue
                }
                
                pcmBufferArray.append(pcmBuffer)
                bufferPosition += bufferSize
            }
            
            if 0 < pcmBufferArray.count {
                self.audioBuffers.append(contentsOf: pcmBufferArray)
                self.prepareBuffer()
            }
        }
    }
    
    /**
     To get data from file or remote repository.
     */
    func setSource(url: String) {
        audioQueue.async { [weak self] in
            guard let self = self else { return }
            
            guard self.lastBuffer != nil else {
                log.error("error: \(DataStreamPlayerError.audioBufferClosed)")
                self.internalStop(notify: false)
                self.state = .error(DataStreamPlayerError.audioBufferClosed)
                return
            }
            
            guard let resourceURL = URL(string: url),
                let resourceData = try? Data(contentsOf: resourceURL) else {
                    log.error("error: \(DataStreamPlayerError.unavailableSource)")
                    self.internalStop(notify: false)
                    self.state = .error(DataStreamPlayerError.unavailableSource)
                return
            }
            
            self.appendData(resourceData)
        }
    }
}

// MARK: private functions
private extension DataStreamPlayer {
    func engineInit() throws {
        if let objcException = (ObjcExceptionCatcher.objcTry {
            guard self.engine.isRunning == false else { return nil }
            
            do {
                try engine.start()
                log.debug("engine started")
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
        player.scheduleBuffer(audioBuffer) { [weak self] in
            self?.audioQueue.async { [weak self] in
                guard let self = self else { return }
                
                #if DEBUG
                if let channelData = audioBuffer.floatChannelData?.pointee {
                    let consumedData = Data(bytes: channelData, count: Int(audioBuffer.frameLength)*4)
                    self.consumedData.append(consumedData)
                }
                #endif
                
                // If player was already stopped. But closure is called
                // This situation will be occured often. Because retrieving audio data from DSP is very hard
                guard self.player.isPlaying else { return }
                
                // If player consumed last buffer
                guard audioBuffer != self.lastBuffer else {
                    self.internalStop(notify: false)
                    self.state = .finish
                    return
                }
                
                self.curBufferIndex += 1
                guard let nextBuffer = self.audioBuffers[safe: self.curBufferIndex] else {
                    log.debug("waiting for next audio data.")
                    
                    NotificationCenter.default.addObserver(forName: .audioBufferChange, object: self, queue: nil) { [weak self] (notification) in
                        guard let self = self else { return }
                        guard let nextBuffer = self.audioBuffers[safe: self.curBufferIndex] else { return }
                        
                        log.debug("Try to restart scheduler.")
                        self.scheduleBuffer(audioBuffer: nextBuffer)
                        
                        NotificationCenter.default.removeObserver(self, name: .audioBufferChange, object: self)
                    }
                    return
                }
                
                self.scheduleBuffer(audioBuffer: nextBuffer)
            }
        }
    }
}

@objc extension DataStreamPlayer {
    func engineConfigurationChange(notification: Notification) {
        log.debug("player will be stopped by changed engine configuration - \(notification)")
        stop()
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
