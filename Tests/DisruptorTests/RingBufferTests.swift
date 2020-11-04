/*
 Copyright 2020 TupleStream OÜ
 See the LICENSE file for license information
 SPDX-License-Identifier: Apache-2.0
*/
import XCTest
@testable import Disruptor
import Atomics

class RingBufferTests: XCTestCase {

    private var executor: DispatchQueue!
    private var ringBuffer: RingBuffer<StubEvent>!
    private var sequenceBarrier: SequenceBarrier!
    private var translator: StubEventTranslator!

    override func setUp() {
        executor = DispatchQueue(label: "RingBufferTests")
        ringBuffer = RingBuffer<StubEvent>.createMultiProducer(factory: StubEventFactory(), bufferSize: 32)
        ringBuffer.addGatingSequences(sequences: NoOpEventProcessor(ringBuffer).sequence)
        sequenceBarrier = ringBuffer.newBarrier()
        translator = StubEventTranslator()
    }

    func testShouldClaimAndGet() {
        XCTAssertEqual(MultiProducerSequencer.initialCursorValue, ringBuffer.cursor)

        let expectedEvent = StubEvent(2701)

        ringBuffer.publishEvent(translator: translator, input: expectedEvent.i)

        let sequence = try! sequenceBarrier.waitFor(sequence: 0)
        XCTAssertEqual(0, sequence)

        let event = ringBuffer.get(sequence: 0)
        XCTAssertEqual(expectedEvent.i, event.i)
        XCTAssertEqual(0, ringBuffer.cursor)
    }

    func testShouldClaimAndGetInSeparateThread() {
        // TODO
    }

    func testShouldClaimAndGetMultipleMessages() {
        for i in 0..<ringBuffer.bufferSize {
            ringBuffer.publishEvent(translator: translator, input: Int(i))
        }

        let expectedSequence = Int64(ringBuffer.bufferSize - 1)
        let available = try! sequenceBarrier.waitFor(sequence: expectedSequence)
        XCTAssertEqual(expectedSequence, available)

        for i in 0..<ringBuffer.bufferSize {
            XCTAssertEqual(Int(i), ringBuffer.get(sequence: Int64(i)).i)
        }
    }

    func testShouldWrap() {
        let numMessages = ringBuffer.bufferSize
        let offset: Int32 = 1000
        for i in 0..<numMessages + offset {
            ringBuffer.publishEvent(translator: translator, input: Int(i))
        }

        let expectedSequence = Int64(ringBuffer.bufferSize + offset - 1)
        let availableSequence = try! sequenceBarrier.waitFor(sequence: expectedSequence)
        XCTAssertEqual(expectedSequence, availableSequence)

        for i in offset..<numMessages + offset {
            let e: StubEvent = ringBuffer.get(sequence: Int64(i))
            let expectedValue = Int(i)
            XCTAssertEqual(expectedValue, e.i)
        }
    }

    func testShouldPreventWrapping() {
        let sequence = Sequence(initialValue: -1)
        ringBuffer = RingBuffer<StubEvent>.createMultiProducer(factory: StubEventFactory(), bufferSize: 4)
        ringBuffer.addGatingSequences(sequences: sequence)

        for i in 0...3 {
            ringBuffer.publishEvent(translator: translator, input: i)
        }

        XCTAssertFalse(ringBuffer.tryPublishEvent(translator: StubEventTranslator(), input: 3))
    }

    func testShouldThrowExceptionIfBufferIsFull() {
        ringBuffer.addGatingSequences(sequences: Sequence(initialValue: Int64(ringBuffer.bufferSize)))

        do {
            for _ in 0..<ringBuffer.bufferSize {
                ringBuffer.publish(try ringBuffer.tryNext())
            }
        } catch {
            XCTFail("Should not throw an exception")
        }

        do {
            let _ = try ringBuffer.tryNext()
            XCTFail("Expected InsufficientCapacityError to be thrown")
        } catch {
            // happy days
        }
    }

    func testShouldPreventPublishersOvertakingEventProcessorWrapPoint() {
        let ringBufferSize = 16
        let latch = CountDownLatch(count: ringBufferSize)
        let publisherComplete = ManagedAtomic<Bool>(false)
        let buffer2 = RingBuffer<StubEvent>.createMultiProducer(factory: StubEventFactory(), bufferSize: Int32(ringBufferSize))

        let processor = TestEventProcessor(buffer2.newBarrier(sequencesToTrack: []))
        buffer2.addGatingSequences(sequences: processor.sequence)

        let work = DispatchWorkItem {
            for i in 0...ringBufferSize { // ..., not ..< here
                let sequence = buffer2.next()
                let event = buffer2.get(sequence: sequence)
                event.i = i
                buffer2.publish(sequence)
                latch.countDown()
            }

            publisherComplete.store(true, ordering: .sequentiallyConsistent)
        }

        DispatchQueue.global().async(execute: work)

        latch.await()

        XCTAssertEqual(buffer2.cursor, Int64(ringBufferSize - 1))
        XCTAssertFalse(publisherComplete.load(ordering: .sequentiallyConsistent))

        processor.run()
        work.wait()

        XCTAssertTrue(publisherComplete.load(ordering: .sequentiallyConsistent))
    }

    func testShouldPublishEvent() {
        
    }
}

fileprivate class TestEventProcessor: EventProcessor {

    let sequence = Sequence(initialValue: -1)
    private let running: ManagedAtomic<Bool> = ManagedAtomic(false)
    private let barrier: SequenceBarrier

    init(_ barrier: SequenceBarrier) {
        self.barrier = barrier
    }

    func run() {
        precondition(running.compareExchange(expected: false, desired: true, ordering: .sequentiallyConsistent).exchanged, "Already running")
        let _ = try! barrier.waitFor(sequence: 0)
        sequence.value = sequence.value + 1
    }

    func halt() {
        running.store(false, ordering: .sequentiallyConsistent)
    }

    var isRunning: Bool {
        get {
            return running.load(ordering: .sequentiallyConsistent)
        }
    }


}
