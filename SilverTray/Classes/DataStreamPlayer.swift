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

        // Attach nodes
        engine.attach(player)
        
        #if !os(watchOS)
        engine.attach(speedController)
        engine.attach(pitchController)
        #endif
        
        // For the sound effects
        connectAudioChain()

        engine.prepare()
        try engineInit()
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
    
    private func connectAudioChain() {
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
    }
    
    public var isPlaying: Bool {
        return player.isPlaying
    }
    
    /**
     Play audio data.
     - You can call this method anytime you want. (this player doesn't care whether entire audio data was appened or not)
     */
    public func play() {
        log.debug("try to play data stream")
        
        do {
            try self.engineInit()
        } catch {
            log.debug("engine init failed: \(error)")
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
            self.state = .error(objcException)
            return
        }

        // if audio session is changed and influence AVAudioEngine, we should handle this.
        NotificationCenter.default.removeObserver(self, name: .AVAudioEngineConfigurationChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(engineConfigurationChange), name: .AVAudioEngineConfigurationChange, object: nil)
    }
    
    public func pause() {
        log.debug("try to pause")
        player.pause()
        isPaused = true
        state = .pause
    }
    
    public func resume() {
        play()
    }
    
    public func stop() {
        log.debug("try to stop")
        reset()
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
    public func lastDataAppended() throws {
        log.debug("Last data appended. No data can be appended any longer.")

        try audioQueue.sync {
            guard lastBuffer == nil else {
                throw DataStreamPlayerError.audioBufferClosed
            }

            if 0 < tempAudioArray.count, let lastPcmData = tempAudioArray.pcmBuffer(format: audioFormat) {
                log.debug("Temp audio data will be scheduled. Because it is last data.")
                audioBuffers.append(lastPcmData)
            }
            
            lastBuffer = audioBuffers.last
            tempAudioArray.removeAll()
            
            guard 0 < audioBuffers.count else {
                log.info("No data appended.")
                reset()
                state = .finish
                return
            }
            
            // last data received but recursive scheduler is not started yet.
            if curBufferIndex == 0 {
                curBufferIndex += (audioBuffers.count - 1)
                for audioBuffer in audioBuffers {
                    scheduleBuffer(audioBuffer: audioBuffer)
                }
            }
            
            log.debug("duration: \(duration)")
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
                log.debug("Decode failed")
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
    func engineInit() throws {
        if let objcException = (ObjcExceptionCatcher.objcTry { [weak self] in
            guard let self = self else { return nil }
            guard self.engine.isRunning == false else { return nil }
            
            do {
                try self.engine.start()
                log.debug("engine started")
            } catch {
                return error
            }
            
            return nil
        }) {
            self.state = .error(objcException)
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
                    self.reset()
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
    
    /**
     Notification must removed before engine stopped.
     Or you may face to exception from inside of AVAudioEngine.
     - ex) AVAudioSession is changed when the audio engine is stopped. but this notification is not removed yet.
     */
    func reset() {
//        NotificationCenter.default.removeObserver(self, name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: .AVAudioEngineConfigurationChange, object: nil)
        NotificationCenter.default.removeObserver(self, name: .audioBufferChange, object: self)
        
        player.stop()
        engine.stop()
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
            
            log.debug("appended data to file :\(appendedFilename)")
            log.debug("consumed data to file :\(consumedFilename)")
        } catch {
            log.debug(error)
        }
        
        appendedData.removeAll()
        consumedData.removeAll()
        #endif
    }
}


@objc private extension DataStreamPlayer {
    func engineConfigurationChange(notification: Notification) {
        if player.isPlaying {
            log.debug("player will be paused by changed engine configuration")
            pause()
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
