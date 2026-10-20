import XCTest
@testable import VoiceOSPlatform

final class BGEWordPieceTests: XCTestCase {
    func tokenizer() throws -> BGEWordPiece {
        var words = (0..<21128).map { "unused-\($0)" }
        for (index,word) in [0:"[PAD]",100:"[UNK]",101:"[CLS]",102:"[SEP]",103:"[MASK]",200:"中",201:"文",202:"。",203:"ABC",204:"café",205:"voice",206:"##os"] { words[index] = word }
        return try BGEWordPiece(vocabulary:words.joined(separator:"\n")+"\n")
    }
    func testChineseAndPunctuationHaveIndependentTokens() throws {
        XCTAssertEqual(try tokenizer().encode("中文。"),[101,200,201,202,102])
    }
    func testCasingAndAccentsAreNotSilentlyNormalized() throws {
        XCTAssertEqual(try tokenizer().encode("ABC café"),[101,203,204,102])
        XCTAssertEqual(try tokenizer().encode("abc cafe"),[101,100,100,102])
    }
    func testGreedyWordPieceAndSpecialMarkers() throws {
        XCTAssertEqual(try tokenizer().encode("voiceos[MASK]"),[101,205,206,103,102])
    }
    func testWhitespaceControlsAndUnknownUnicode() throws {
        XCTAssertEqual(try tokenizer().encode("中\t\n文\u{0000}\u{200B}。🙂"),[101,200,201,202,100,102])
    }
    func testLimitsRejectTokenOverflowRatherThanTruncating() throws {
        XCTAssertEqual(try tokenizer().encode(String(repeating:"a",count:101)),[101,100,102])
        XCTAssertThrowsError(try tokenizer().encode(String(repeating:"中",count:511)))
    }
    func testMalformedVocabularyRejects() throws {
        XCTAssertThrowsError(try BGEWordPiece(vocabulary:"[CLS]\n[SEP]\n"))
    }
}
