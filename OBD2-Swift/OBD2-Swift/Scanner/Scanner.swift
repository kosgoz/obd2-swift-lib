//
//  Sanner.swift
//  OBD2Swift
//
//  Created by Max Vitruk on 24/05/2017.
//  Copyright © 2017 Lemberg. All rights reserved.
//

import Foundation

enum ReadInputError: Error {
    case initResponseUnreadable
}

enum InitScannerError: Error {
    case outputTimeout
    case inputTimeout
}

public typealias StateChangeCallback = (_ state: ScanState) -> ()

class `Scanner`: StreamHolder {
    
    typealias CallBack = (Bool, Error?) -> ()
    
    let timeout	= 10.0
    
    var defaultSensors: [UInt8] = [0x0C, 0x0D]
    
    var supportedSensorList = [Int]()
    open var sensorScanTargets = [UInt8]()
    
    var currentSensorIndex = 0
    var streamOperation: Operation!
    var scanOperationQueue: OperationQueue!
    
    var priorityCommandQueue: [DataRequest] = []
    var commandQueue: [DataRequest] = []
    
    var state: ScanState = .none {
        didSet {
            if state == .none {
                obdQueue.cancelAllOperations()
            }
            stateChanged?(state)
        }
    }
    
    var stateChanged: StateChangeCallback?
    
    var `protocol`: ScanProtocol = .none
    var waitingForVoltageCommand = false
    var currentPIDGroup: UInt8 = 0x00
    
    var maxSize = 512
    var readBuf = [UInt8]()
    var readBufLength = 0
    
    init(host: String, port: Int) {
        super.init()
        self.host = host
        self.port = port
        
        delegate = self
    }
    
    open func setupProtocol(buffer: [UInt8]) -> ScanProtocol {
        let asciistr: [Int8] = buffer.map({Int8.init(bitPattern: $0)})
        let respString = String.init(cString: asciistr, encoding: String.Encoding.ascii) ?? ""
        
        var searchIndex = 0
        if Parser.string.isAuto(respString) {
            // The 'A' is for Automatic.  The actual
            // protocol number is at location 1, so
            // increment pointer by 1
            //asciistr += 1
            searchIndex += 1
        }
        
        let uintIndex =  asciistr[searchIndex] - 0x4E
        let index = Int(uintIndex)
        
        self.`protocol` = elmProtocolMap[index]
        return self.`protocol`
    }
    
    open func request(command: DataRequest) {
        self.request(command: command) { (response) in
            print("Receive response \(response)")
        }
    }
    
    
    open func request(command: DataRequest, response : @escaping (_ response:Response) -> ()){
        
        let request = CommandOperation(inputStream: inputStream, outputStream: outputStream, command: command)
        
        request.onReceiveResponse = response
        request.queuePriority = .high
        request.completionBlock = {
            print("Request operation completed")
        }
        
        obdQueue.addOperation(request)
    }
    
    open func request(repeat command: DataRequest, response : @escaping (_ response:Response) -> ()) {
        let request = CommandOperation(inputStream: inputStream, outputStream: outputStream, command: command)
        
        request.queuePriority = .low
        request.onReceiveResponse = response
        request.completionBlock = { [weak self] in
            print("Request operation completed")
            if let error = request.error {
                self?.obdQueue.cancelAllOperations()
                self?.state = .none
            } else {
                guard let strong = self else { return }
                strong.request(repeat: command, response: response)
            }
        }
        
        obdQueue.addOperation(request)
    }
    
    open func setSensorScanTargets(targets : [UInt8]){
        sensorScanTargets.removeAll()
        sensorScanTargets = targets
        
        guard let cmd = dequeueCommand() else {return}
        request(command: cmd)
        writeCachedData()
    }
    
    open func isScanning() -> Bool {
        return streamOperation?.isCancelled ?? false
    }
    
    open func startScan(callback: @escaping CallBack){
        
        if state != .none {
            return
        }
        
        state = .openingConnection
        
        obdQueue.cancelAllOperations()
        
        createStreams()
        
        // Open connection to OBD
        
        let openConnectionOperation = OpenOBDConnectionOperation(inputStream: inputStream, outputStream: outputStream)
        
        openConnectionOperation.completionBlock = { [weak self] in
            if let error = openConnectionOperation.error {
                print("open operation completed with error \(error)")
                self?.state = .none
                self?.obdQueue.cancelAllOperations()
            } else {
                self?.state = .initializing
                print("open operation completed without errors")
            }
        }
        
        obdQueue.addOperation(openConnectionOperation)
        
        // Initialize connection with OBD

        let initOperation = InitScanerOperation(inputStream: inputStream, outputStream: outputStream)
        
        initOperation.completionBlock = { [weak self] in
            if let error = initOperation.error {
                callback(false, error)
                self?.state = .none
                self?.obdQueue.cancelAllOperations()
            } else {
                self?.state = .connected
                callback(true, nil)
            }
        }
        
        obdQueue.addOperation(initOperation)
    }
    
    open func pauseScan() {
        obdQueue.isSuspended = true
    }
    
    open func resumeScan() {
        obdQueue.isSuspended = false
    }
    
    open func cancelScan() {
        obdQueue.cancelAllOperations()
    }
    
    open func disconnect() {
        cancelScan()
        inputStream.close()
        outputStream.close()
        state = .none
    }
    
    open func isService01PIDSupported(pid : Int) -> Bool {
        var supported = false
        
        for supportedPID in supportedSensorList {
            if supportedPID == pid {
                supported = true
                break
            }
        }
        
        return supported
    }

    private func enqueueCommand(command: DataRequest) {
        priorityCommandQueue.append(command)
    }
    
    private func clearCommandQueue(){
        priorityCommandQueue.removeAll()
    }
    
    private func dequeueCommand() -> DataRequest? {
        var cmd: DataRequest?
        
        if priorityCommandQueue.count > 0 {
            cmd = priorityCommandQueue.remove(at: 0)
        }else if sensorScanTargets.count > 0 {
            cmd = commandForNextSensor()
        }
        
        return cmd
    }
    
    private func commandForNextSensor() -> DataRequest? {
        if currentSensorIndex >= sensorScanTargets.count {
            currentSensorIndex = 0
            
            // Put a pending DTC request in the priority queue, to be executed
            // after the battery voltage reading
            
            waitingForVoltageCommand = true
            return Command.AT.reset.dataRequest
        }
        
        let next = self.nextSensor()
        
        if next <= 0x4E {
            return DataRequest(mode: .CurrentData01, pid: next)
        }else {
            return nil
        }
    }
    
    private func nextSensor() -> UInt8 {
        if currentSensorIndex > sensorScanTargets.count {
            currentSensorIndex = 0
        }
        
        let number = sensorScanTargets[currentSensorIndex]
        currentSensorIndex += 1
        
        return number
    }
    
    //MARK: - Scanning Operation
    
    //    private func runStreams(){
    //        let currentRunLoop	= RunLoop.current
    //        let distantFutureDate	= Date.distantFuture
    //
    //        open()
    //
    //        //TODO: Error cases
    //        do {
    //            try initScanner()
    //        } catch InitScannerError.inputTimeout {
    //            print("Error: Input stream opening error.")
    //        } catch InitScannerError.outputTimeout {
    //            print("Error: Output stream opening error. ")
    //        } catch {
    //            print("Error: Unrecognized streams opening error")
    //        }
    //
    //        while streamOperation?.isCancelled == false && currentRunLoop.run(mode: .defaultRunLoopMode, before: distantFutureDate) {/*loop */}
    //
    //        close()
    //    }
    
    //TODO: - Refactor wanted
    //  fileprivate func readVoltageResponse()  {
    //    let readLength = inputStream.read(&readBuf, maxLength: readBufLength)
    //
    //    guard readLength > 0 else {
    //        //TODO: no input response
    //        return
    //    }
    //
    //    var buff = readBuf
    //    buff.removeSubrange(readLength..<maxSize)
    //
    //    readBufLength = readLength
    //
    //    if ELM_READ_COMPLETE(buff) {
    //      state			= .processing
    //
    //      if (readBufLength - 3) > 0 && (readBufLength - 3) < buff.count {
    //        buff[(readBufLength - 3)] = 0x00
    //        readBufLength	-= 3
    //      }
    //
    //      let asciistr : [Int8] = buff.map({Int8.init(bitPattern: $0)})
    //      let respString = String.init(cString: asciistr, encoding: String.Encoding.ascii) ?? ""
    //      print(respString)
    //
    //      if ELM_ERROR(respString) {
    //        initState	= .RESET
    //        state       = .init
    //      } else {
    //        state       = .idle
    //
    //        if let cmd = dequeueCommand() {
    //          request(command: cmd)
    //        }
    //      }
    //    } else {
    //      state = .waiting
    //    }
    //
    //    if state == .idle || state == .init {
    //      eraseBuffer()
    //      waitingForVoltageCommand	= false
    //    }
    //  }
    
    private func eraseBuffer(){
        readBufLength = 0
        readBuf.removeAll()
    }
}

extension Scanner: StreamFlowDelegate {
    func didOpen(stream: Stream){
        
    }
    
    func error(_ error: Error, on stream: Stream){
        
    }
    
    func hasInput(on stream: Stream){
        //
        //    do {
        //
        //        if state == .init {
        //          try readInitResponse()
        //        } else if state == .idle || state == .waiting {
        //            waitingForVoltageCommand ? readVoltageResponse() : readInput()
        //
        //        } else {
        //          print("Error: Received bytes in unknown state: \(state)")
        //        }
        //
        //    } catch {
        //
        //        print("Error: Init response unreadable. Need reconnect")
        //        //TODO: try reconnect
        //    }
        //
        //
    }
}

extension Scanner {
    enum State : UInt {
        case unknown			= 1
        case reset				= 2
        case echoOff			= 4
        case version 			= 8
        case search       = 16
        case `protocol`   = 32
        case complete     = 64
        
        static var all : [State] {
            return [.unknown, .reset, .echoOff, .version, .search, .`protocol`, .complete]
        }
        
        static func <<= (left: State, right: UInt) -> State {
            let move = left.rawValue << right
            return self.all.filter({$0.rawValue == move}).first ?? .unknown
        }
        
        mutating func next() {
            self = self <<= 1
        }
    }
}