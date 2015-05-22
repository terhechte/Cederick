//
//  Cederic.swift
//  Cederic
//
//  Created by Benedikt Terhechte on 21/05/15.
//  Copyright (c) 2015 Benedikt Terhechte. All rights reserved.
//

import Foundation
import Dispatch

/*
TODO:
- [ ] 12% CPU on Retina 13" (2012) with 500 agents. Also leaks memory
- [ ] 10% CPU on Retina 13" (2012) with 5000 agents. No leaks. Much better.
- [ ] make .value bindings compatible (willChangeValue..)
- [ ] add lots and lots of tests
- [ ] define operators for easy equailty
- [ ] find a better way to process the blocks than usleep (select?)
- [ ] this is an undocumented mess. make it useful
- [ ] solo and blocking actions
- [ ] move most methods out of the class so that they're more functional and can be curried etc (i.e. send(agent, clojure)
- [ ] make the kMaountOfPooledQueues dependent upon the cores in a machine
- [ ] don't just randomly select a queue in the AgentQueueManager, but the queue with the least amount of operations, or at least the longest-non-added one. (could use atomic operations to store this)
Most of the clojure stuff:
- [ ] Remove a Watch
- [ ] The watch fn must be a fn of 4 args: a key, the reference, its old-state, its new-state.
- [ ] error handling (see https://github.com/clojure/clojure/blob/028af0e0b271aa558ea44780e5d951f4932c7842/src/clj/clojure/core.clj#L2002
- [ ] restarting
- [ ] update the code to use barriers

Try removing the usleep by one of those means:
- kqueue: http://www.freebsd.org/cgi/man.cgi?query=kqueue&sektion=2
EVFILT_USER    Establishes	a user event identified	by ident which is not
associated with any	kernel mechanism but is	triggered by
user level code.  The lower	24 bits	of the fflags may be
used for user defined flags	and manipulated	using the fol-
lowing:
A user event is triggered for output with the following:
NOTE_TRIGGER       Cause the event to be triggered.

- dispatch_group/barrier: http://www.objc.io/issue-2/low-level-concurrency-apis.html

Notes:
- Tried to use dispatch_after instead of usleep, as I expected it would sleep the block until it was needed again, but that lead to much
  worse performance.

*/

let kAmountOfPooledQueues = 4




/*!
@abstract lazy vars can only exist in a struc or class or enum right now so we've to wrap it
*/
class AgentQueueManager {
    lazy var agentConcurrentQueue = dispatch_queue_create("com.stylemac.agentConcurrentQueue", DISPATCH_QUEUE_CONCURRENT)
    lazy var agentProcessQueue = dispatch_queue_create("com.stylemac.agentProcessQueue", DISPATCH_QUEUE_SERIAL)
    lazy var agentBlockQueue = dispatch_queue_create("com.stylemac.agentBlockQueue", DISPATCH_QUEUE_SERIAL)
    lazy var agentQueuePool: [dispatch_queue_t] = {
        var p: [dispatch_queue_t] = []
        for i in 0...kAmountOfPooledQueues {
            p.append(dispatch_queue_create("com.stylemac.AgentPoolQueue-\(i)", DISPATCH_QUEUE_SERIAL))
        }
        return p
    }()
    var operations: [()->()] = []
    
    init() {
        self.perform()
    }
    
    /* // compiler doesn't like this. should file a radar
    lazy var agentQueuePool: [dispatch_queue_t] = { ()->[dispatch_queue_t] in
        return 0...4.map { (n: Int)->dispatch_queue_t in
            dispatch_queue_create("AgentPoolQueue-\(n)", DISPATCH_QUEUE_SERIAL)
        }
    }()*/
    var anyPoolQueue: dispatch_queue_t {
        let pos = Int(arc4random_uniform(UInt32(kAmountOfPooledQueues) + UInt32(1)))
        return agentQueuePool[pos]
    }
    
    func add(op: ()->()) {
        dispatch_async(self.agentProcessQueue , { () -> Void in
                self.operations.append(op)
        })
    }
    
    func perform() {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), { () -> Void in
            var lstv = 0
            var evlist = UnsafeMutablePointer<kevent>.alloc(10)
            while (true) {
                
                println("waiting")
                
                let newEvent = kevent(k, nil, 0, evlist, 10, nil)
                
                if newEvent > 0 {
                    
                    let uvx = evlist[0].udata
//                    println("got events (\(evlist[0].data))", address(&evlist))
                    let px = UnsafeMutablePointer<Int32>(uvx)
                    println("ev: \(px.memory) c: \(newEvent)")
                    if Int(px.memory) != Int(lstv) {
                        println("missed a package! is: \(lstv) has: \(px.memory) eventcount: \(newEvent)")
                    }
                    lstv += 1
                    
                    dispatch_sync(self.agentProcessQueue, { () -> Void in
                        self.operations.map {op in op()}
                    })
                    
                    let cx = EV_DISABLE
                    let fx = 0
                    var ev = kevent(ident: UInt(42), filter: Int16(EVFILT_USER), flags: UInt16(cx), fflags: UInt32(fx), data: Int(0), udata: ud)
                    let er = kevent(k, &ev, 1, nil, 0, nil)
                }
                
//                let milliseconds:useconds_t  = 10
//                usleep(milliseconds * 1000)
            }
        })
    }
}

// FIXME: Make sure this will only be evaluated once!
// maybe dispatch-once it?
var queueManager = AgentQueueManager()


enum AgentSendType {
    case Solo
    case Pooled
}

private var once = dispatch_once_t()

public class Agent<T> {
    
    typealias AgentAction = (T)->T
    typealias AgentValidator = (T)->Bool
    typealias AgentWatch = (T)->Void
    
    public var value: T {
        return state
    }
    
    private var state: T
    private let validator: AgentValidator?
    private var watches:[AgentWatch]
    private var actions: [(AgentSendType, AgentAction)]
    private var stop = false
    //private var opidx = 0
    
    init(initialState: T, validator: AgentValidator?) {
        
        self.state = initialState
        self.validator = validator
        self.watches = []
        self.actions = []
        queueManager.add(self.process)
    }
    
    func send(fn: AgentAction) {
        dispatch_async(queueManager.agentBlockQueue, { () -> Void in
            self.actions.append((AgentSendType.Pooled, fn))
            swKqueuePostEvent()
        })
    }
    func sendOff(fn: AgentAction) {
        dispatch_async(queueManager.agentBlockQueue, { () -> Void in
            self.actions.append((AgentSendType.Solo, fn))
            swKqueuePostEvent()
        })
    }
    func addWatch(watch: AgentWatch) {
        self.watches.append(watch)
    }
    func destroy() {
        self.stop = true
    }
    func calculate(f: AgentAction) {
        let newValue = f(self.state)
        if let v = self.validator {
            if !v(newValue) {
                return
            }
        }
        
        self.state = newValue
        
        for watch in self.watches {
            watch(newValue)
        }
    }
    
    func process() {
            var fn: (AgentSendType, AgentAction)?
            
            dispatch_sync(queueManager.agentBlockQueue, { () -> Void in
                if self.actions.count > 0 {
                    fn = self.actions.removeAtIndex(0)
                }
            })
            
            switch fn {
            case .Some(.Pooled, let f):
                dispatch_async(queueManager.anyPoolQueue, { () -> Void in
                    self.calculate(f)
                })
            case .Some(.Solo, let f):
                // Create and destroy a queue just for this
                let uuid = NSUUID().UUIDString
                let ourQueue = dispatch_queue_create(uuid, nil)
                dispatch_async(ourQueue, { () -> Void in
                    self.calculate(f)
                })
            default: ()
            }
    }
}

