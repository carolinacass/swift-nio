//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2022 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import DequeModule
import NIOConcurrencyHelpers

#if compiler(>=5.5.2) && canImport(_Concurrency)
/// A protocol for the back-pressure strategy of the ``NIOAsyncSequenceProducer``.
///
/// A back-pressure strategy is invoked when new elements are yielded to the sequence or
/// when a ``NIOAsyncSequenceProducer/AsyncIterator`` requested the next value. The responsibility of the strategy is
/// to determine whether more elements need to be produced .
///
/// If more elements need to be produced, either the ``NIOAsyncSequenceProducerDelegate/produceMore()``
/// method will be called or a ``NIOAsyncSequenceProducer/Source/YieldResult`` will be returned that indicates
/// to produce more.
///
/// - Important: The methods of this protocol are guaranteed to be called serially. Furthermore, the implementation of these
/// methods **MUST NOT** do any locking or call out to any other Task/Thread.
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public protocol NIOAsyncSequenceProducerBackPressureStrategy: Sendable {
    /// This method is called after new elements were yielded by the producer to the source.
    ///
    /// - Parameter bufferDepth: The current depth of the internal buffer of the sequence. The buffer contains all
    /// the yielded but not yet consumed elements.
    /// - Returns: Returns whether more elements should be produced.
    mutating func didYield(bufferDepth: Int) -> Bool

    /// This method is called after the consumer consumed an element.
    /// More specifically this method is called after `next` was called on an iterator of the ``NIOAsyncSequenceProducer``.
    ///
    /// - Parameter bufferDepth: The current depth of the internal buffer of the sequence. The buffer contains all
    /// the yielded but not yet consumed elements.
    /// - Returns: Returns whether the producer should produce more elements.
    mutating func didConsume(bufferDepth: Int) -> Bool
}

/// The delegate of ``NIOAsyncSequenceProducer``.
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public protocol NIOAsyncSequenceProducerDelegate: Sendable {
    /// This method is called once the back-pressure strategy of the ``NIOAsyncSequenceProducer`` determined
    /// that the producer needs to produce more elements.
    ///
    /// - Note: ``NIOAsyncSequenceProducerDelegate/produceMore()`` will never be called after
    /// ``NIOAsyncSequenceProducerDelegate/didTerminate()`` was called.
    ///
    /// - Important: This is only called as a result of the consumer calling ``NIOAsyncSequenceProducer/AsyncIterator/next()``.
    /// It is never called as a result of a producer calling ``NIOAsyncSequenceProducer/Source/yield(_:)``.
    func produceMore()

    /// This method is called once the ``NIOAsyncSequenceProducer`` is terminated.
    ///
    /// Termination happens if:
    /// - The ``NIOAsyncSequenceProducer/AsyncIterator`` is deinited.
    /// - The ``NIOAsyncSequenceProducer`` deinited and no iterator is alive.
    /// - The consuming `Task` is cancelled (e.g. `for await let element in`).
    /// - The source finished and all remaining buffered elements have been consumed.
    func didTerminate()
}

/// This is an ``Swift/AsyncSequence`` that supports a unicast ``Swift/AsyncIterator``.
///
/// The goal of this sequence is to produce a stream of elements from the _synchronous_ world
/// (e.g. elements from a ``Channel`` pipeline) and vend it to the _asynchronous_ world for consumption.
/// Furthermore, it provides facilities to implement a back-pressure strategy which
/// observes the number of elements that are yielded and consumed. This allows to signal the source to request more data.
///
/// - Note: It is recommended to never directly expose this type from APIs, but rather wrap it. This is due to the fact that
/// this type has three generic parameters where at least two should be known statically and it is really awkward to spell out this type.
/// Moreover, having a wrapping type allows to optimize this to specialized calls if all generic types are known.
///
/// - Important: This sequence is a unicast sequence that only supports a single ``NIOAsyncSequenceProducer/AsyncIterator``.
/// If you try to create more than one iterator it will result in a `fatalError`.
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public struct NIOAsyncSequenceProducer<
    Element: Sendable,
    Strategy: NIOAsyncSequenceProducerBackPressureStrategy,
    Delegate: NIOAsyncSequenceProducerDelegate
>: Sendable {
    /// Simple struct for the return type of ``NIOAsyncSequenceProducer/makeSequence(of:backPressureStrategy:delegate:)``.
    ///
    /// This struct contains two properties:
    /// 1. The ``source`` which should be retained by the producer and is used
    /// to yield new elements to the sequence.
    /// 2. The ``sequence`` which is the actual ``Swift/AsyncSequence`` and
    /// should be passed to the consumer.
    public struct NewSequence {
        /// The source of the ``NIOAsyncSequenceProducer`` used to yield and finish.
        public let source: Source
        /// The actual sequence which should be passed to the consumer.
        public let sequence: NIOAsyncSequenceProducer

        @usableFromInline
        /* fileprivate */ internal init(
            source: Source,
            sequence: NIOAsyncSequenceProducer
        ) {
            self.source = source
            self.sequence = sequence
        }
    }

    @usableFromInline
    /* private */ internal let throwingSequence: NIOThrowingAsyncSequenceProducer<
        Element,
        Never,
        Strategy,
        Delegate
    >

    /// Initializes a new ``NIOAsyncSequenceProducer`` and a ``NIOAsyncSequenceProducer/Source``.
    ///
    /// - Important: This method returns a struct containing a ``NIOAsyncSequenceProducer/Source`` and
    /// a ``NIOAsyncSequenceProducer``. The source MUST be held by the caller and
    /// used to signal new elements or finish. The sequence MUST be passed to the actual consumer and MUST NOT be held by the
    /// caller. This is due to the fact that deiniting the sequence is used as part of a trigger to terminate the underlying source.
    ///
    /// - Parameters:
    ///   - element: The element type of the sequence.
    ///   - backPressureStrategy: The back-pressure strategy of the sequence.
    ///   - delegate: The delegate of the sequence
    /// - Returns: A ``NIOAsyncSequenceProducer/Source`` and a ``NIOAsyncSequenceProducer``.
    @inlinable
    public static func makeSequence(
        of elementType: Element.Type = Element.self,
        backPressureStrategy: Strategy,
        delegate: Delegate
    ) -> NewSequence {
        let newSequence = NIOThrowingAsyncSequenceProducer.makeSequence(
            elementType: Element.self,
            failureType: Never.self,
            backPressureStrategy: backPressureStrategy,
            delegate: delegate
        )

        let sequence = self.init(throwingSequence: newSequence.sequence)

        return .init(source: Source(throwingSource: newSequence.source), sequence: sequence)
    }

    @inlinable
    /* private */ internal init(
        throwingSequence: NIOThrowingAsyncSequenceProducer<Element, Never, Strategy, Delegate>
    ) {
        self.throwingSequence = throwingSequence
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension NIOAsyncSequenceProducer: AsyncSequence {
    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(throwingIterator: self.throwingSequence.makeAsyncIterator())
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension NIOAsyncSequenceProducer {
    public struct AsyncIterator: AsyncIteratorProtocol {
        @usableFromInline
        /* private */ internal let throwingIterator: NIOThrowingAsyncSequenceProducer<
            Element,
            Never,
            Strategy,
            Delegate
        >.AsyncIterator

        fileprivate init(
            throwingIterator: NIOThrowingAsyncSequenceProducer<
                Element,
                Never,
                Strategy,
                Delegate
            >.AsyncIterator
        ) {
            self.throwingIterator = throwingIterator
        }

        @inlinable
        public func next() async -> Element? {
            return try! await self.throwingIterator.next()
        }
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension NIOAsyncSequenceProducer {
    /// A struct to interface between the synchronous code of the producer and the asynchronous consumer.
    /// This type allows the producer to synchronously `yield` new elements to the ``NIOThrowingAsyncSequenceProducer``
    /// and to `finish` the sequence.
    public struct Source {
        @usableFromInline
        /* fileprivate */ internal let throwingSource: NIOThrowingAsyncSequenceProducer<
            Element,
            Never,
            Strategy,
            Delegate
        >.Source

        @usableFromInline
        /* fileprivate */ internal init(
            throwingSource: NIOThrowingAsyncSequenceProducer<
                Element,
                Never,
                Strategy,
                Delegate
            >.Source
        ) {
            self.throwingSource = throwingSource
        }

        /// The result of a call to ``NIOThrowingAsyncSequenceProducer/Source/yield(_:)``.
        public enum YieldResult: Hashable {
            /// Indicates that the caller should produce more elements.
            case produceMore
            /// Indicates that the caller should stop producing elements.
            case stopProducing
            /// Indicates that the yielded elements have been dropped because the sequence already terminated.
            case dropped
        }

        /// Yields a sequence of new elements to the ``NIOThrowingAsyncSequenceProducer``.
        ///
        /// If there is an ``NIOThrowingAsyncSequenceProducer/AsyncIterator`` awaiting the next element, it will get resumed right away.
        /// Otherwise, the element will get buffered.
        ///
        /// If the ``NIOThrowingAsyncSequenceProducer`` is terminated this will drop the elements
        /// and return ``YieldResult/dropped``.
        ///
        /// This can be called more than once and returns to the caller immediately
        /// without blocking for any awaiting consumption from the iteration.
        ///
        /// - Parameter contentsOf: The sequence to yield.
        /// - Returns: A ``NIOThrowingAsyncSequenceProducer/Source/YieldResult`` that indicates if the yield was successful
        /// and if more elements should be produced.
        @inlinable
        public func yield<S: Sequence>(contentsOf sequence: S) -> YieldResult where S.Element == Element {
            switch self.throwingSource.yield(contentsOf: sequence) {
            case .stopProducing:
                return .stopProducing
            case .produceMore:
                return .produceMore
            case .dropped:
                return .dropped
            }
        }

        /// Yields a new elements to the ``NIOThrowingAsyncSequenceProducer``.
        ///
        /// If there is an ``NIOThrowingAsyncSequenceProducer/AsyncIterator`` awaiting the next element, it will get resumed right away.
        /// Otherwise, the element will get buffered.
        ///
        /// If the ``NIOThrowingAsyncSequenceProducer`` is terminated this will drop the elements
        /// and return ``YieldResult/dropped``.
        ///
        /// This can be called more than once and returns to the caller immediately
        /// without blocking for any awaiting consumption from the iteration.
        ///
        /// - Parameter element: The element to yield.
        /// - Returns: A ``NIOThrowingAsyncSequenceProducer/Source/YieldResult`` that indicates if the yield was successful
        /// and if more elements should be produced.
        @inlinable
        public func yield(_ element: Element) -> YieldResult {
            self.yield(contentsOf: CollectionOfOne(element))
        }

        /// Finishes the sequence.
        ///
        /// Calling this function signals the sequence that there won't be any subsequent elements yielded.
        ///
        /// If there are still buffered elements and there is an ``NIOThrowingAsyncSequenceProducer/AsyncIterator`` consuming the sequence,
        /// then termination of the sequence only happens once all elements have been consumed by the ``NIOThrowingAsyncSequenceProducer/AsyncIterator``.
        /// Otherwise, the buffered elements will be dropped.
        ///
        /// - Note: Calling this function more than once has no effect.
        @inlinable
        public func finish() {
            self.throwingSource.finish()
        }
    }
}

/// The ``NIOAsyncSequenceProducer/AsyncIterator`` MUST NOT be shared across `Task`s. With marking this as
/// unavailable we are explicitly declaring this.
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
@available(*, unavailable)
extension NIOAsyncSequenceProducer.AsyncIterator: Sendable {}
#endif
