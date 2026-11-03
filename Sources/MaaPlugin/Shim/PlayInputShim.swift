//
//  PlayInputShim.swift
//  MaaPlugin
//
//  PlayTools' PlayInput owns the serial queue that all touch injection runs on.
//  Only the queue is needed here; the value is copied from PlayTools'
//  PlayInput.swift so the vendored MaaTools.swift keeps its threading contract
//  ("All reads and writes must occur on PlayInput.touchQueue").
//

import Foundation

final class PlayInput {
    static var touchQueue = DispatchQueue.init(label: "playcover.toucher",
                                               qos: .userInteractive,
                                               autoreleaseFrequency: .workItem)
}
