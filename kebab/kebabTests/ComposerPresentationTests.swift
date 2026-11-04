//
//  ComposerPresentationTests.swift
//  kebabTests
//
//  The inline composer and the full-screen one never show the draft together.
//

import Testing
@testable import kebab

@Suite("Composer presentation")
struct ComposerPresentationTests {

    @Test("The inline composer shows until full screen opens, then hides at once")
    func opening() {
        var presentation = ComposerPresentation()
        #expect(!presentation.hidesInline)
        #expect(!presentation.isFullScreen)
        presentation.open()
        #expect(presentation.hidesInline)
        #expect(presentation.isFullScreen)
    }

    @Test("It stays hidden until the overlay has finished leaving")
    func closing() {
        var presentation = ComposerPresentation()
        presentation.open()
        presentation.close()
        #expect(!presentation.isFullScreen)
        #expect(presentation.hidesInline)
        presentation.finishLeaving()
        #expect(!presentation.hidesInline)
    }

    @Test("A draft comes back resting collapsed, until something expands it")
    func collapsedOnReturn() {
        var presentation = ComposerPresentation()
        #expect(!presentation.restsCollapsed)
        presentation.open()
        #expect(!presentation.restsCollapsed)
        presentation.close()
        presentation.finishLeaving()
        #expect(presentation.restsCollapsed)
        presentation.open()
        #expect(!presentation.restsCollapsed)
    }

    @Test("Reopening during the slide away keeps full screen up")
    func reopenWhileLeaving() {
        var presentation = ComposerPresentation()
        presentation.open()
        presentation.close()
        presentation.open()
        presentation.finishLeaving()
        #expect(presentation.isFullScreen)
        #expect(presentation.hidesInline)
    }

    @Test("A stray close or finish changes nothing")
    func strayCalls() {
        var presentation = ComposerPresentation()
        presentation.close()
        presentation.finishLeaving()
        #expect(presentation == ComposerPresentation())
    }
}
