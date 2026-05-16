import Foundation
import zlib

// MARK: - AiFileModel

struct AiFileModel {
    var url: URL

    var kind: String = ""               // "Ai" / "EPS" / "PDF"（Illustrator編集機能保持PDFを .ai に偽装したもの）
    var appName: String = ""            // "Illustrator" or "Photoshop"
    var isIllustratorFile: Bool = false
    var isTemplate: Bool = false        // true = 本物の Illustrator テンプレート（.ait）形式

    var finderInfoFileType: String = ""
    var finderInfoCreator: String = ""
    var xmpCreatorTool: String = ""

    var creator1: String = ""
    var creator2: String = ""
    var ai8CreatorVersion: String = ""
    var hasCreator2: Bool = true

    var determineCreated: String = ""
    var determineSaved: String = ""
    var isSavedLowerVersion: Bool = false
    var isTimeOut: Bool = false

    var timeXmpCreatorTool: Double = 0
    var timeCreator1: Double = 0
    var timeAI8CreatorVersion: Double = 0
    var timeCreator2: Double = 0
    var timeTotalSeconds: Double = 0
}

// MARK: - FileParser

nonisolated enum FileParser {

    // MARK: - Entry

    static func parse(url: URL, timeLimit: Double, notDetectEPSCompatibleVer: Bool,
                      notDetectXMP: Bool = false) -> AiFileModel {
        var fc = AiFileModel(url: url)
        let startTotal = Date()

        // 1. Finder info
        let (fileType, creator) = getFinderInfo(url: url)
        fc.finderInfoFileType = fileType
        fc.finderInfoCreator = creator

        // PDF構造かどうかを早期判定し、xref を一度だけ解析して以降で共有する
        // （XMP取得とバージョンスキャンの両方で使用）
        let pdfXref: (root: Int, offsets: [Int: UInt64])? = {
            guard isPDFBased(url: url),
                  let fh = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? fh.close() }
            return parsePDFXref(fh: fh)
        }()

        // 2. XMP CreatorTool
        // ・PDF構造ファイル  → xref 経由で Metadata オブジェクトを直接読む（高速）
        // ・非PDF の .ai/.ait → xmp:CreatorTool が存在しないためスキップ
        // ・その他（EPS等）  → 従来の逐次スキャン
        // ・notDetectXMP=true → 全種別スキップ
        let t = Date()
        if !notDetectXMP {
            if let xref = pdfXref {
                if let fh = try? FileHandle(forReadingFrom: url) {
                    defer { try? fh.close() }
                    fc.xmpCreatorTool = getCreatorToolViaXref(root: xref.root,
                                                              offsets: xref.offsets, fh: fh)
                }
            } else {
                let ext = url.pathExtension.lowercased()
                if ext != "ai" && ext != "ait" {
                    fc.xmpCreatorTool = getCreatorTool(url: url)
                }
            }
        }
        if !notDetectXMP && fc.xmpCreatorTool.isEmpty {
            fc.xmpCreatorTool = "CreatorToolなし"
        }
        fc.timeXmpCreatorTool = Date().timeIntervalSince(t)

        // 3. ファイル種別判定（拡張子非依存・コンテンツベース）
        fc.kind = getFileKind(fc: &fc, pdfXref: pdfXref)

        // 4. XMP CreatorTool による補完（非PDF構造ファイルで Creator コメントが欠落しているケース）
        if !fc.isIllustratorFile && pdfXref == nil && fc.xmpCreatorTool.contains("Illustrator") {
            if fc.kind == "Ai" || fc.kind == "EPS" {
                fc.isIllustratorFile = true
            }
        }

        // 5. バージョンコメントをスキャン
        if fc.isIllustratorFile {
            if let xref = pdfXref {
                // PDF構造: 解析済み xref を使い AIMetaData を直接読む
                scanVersionCommentsFromPDF(xref: xref, url: url, fc: &fc)
            } else {
                // 非PDF（EPS・旧来 AI 等）: 逐次スキャン
                scanVersionComments(url: url, fc: &fc, timeLimit: timeLimit,
                                    notDetectEPSCompatibleVer: notDetectEPSCompatibleVer,
                                    startTotal: startTotal)
            }
            determineVersion(fc: &fc)
        } else {
            fc.hasCreator2 = false
        }

        // 6. アプリ名
        if fc.isIllustratorFile {
            fc.appName = "Illustrator"
        } else if isPhotoshopFile(url: url, kind: fc.kind) || fc.xmpCreatorTool.contains("Photoshop") {
            fc.appName = "Photoshop"
        }

        fc.timeTotalSeconds = Date().timeIntervalSince(startTotal)
        return fc
    }

    // MARK: - Finder Info

    static func getFinderInfo(url: URL) -> (fileType: String, creator: String) {
        let path = url.path
        let attrName = "com.apple.FinderInfo"
        var buf = [UInt8](repeating: 0, count: 32)
        let result = getxattr(path, attrName, &buf, 32, 0, 0)
        guard result >= 8 else { return ("", "") }
        let fileType = String(bytes: buf[0..<4], encoding: .macOSRoman) ?? ""
        let creator  = String(bytes: buf[4..<8], encoding: .macOSRoman) ?? ""
        return (fileType, creator)
    }

    // MARK: - XMP CreatorTool

    static func getCreatorTool(url: URL) -> String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = attrs[.size] as? Int else { return "" }

        for limit in [1_000_000, 10_000_000, 50_000_000] {
            if fileSize <= limit || limit == 50_000_000 {
                if let s = creatorToolFromBinary(url: url, byteCount: min(limit, fileSize)) {
                    return s
                }
                break
            }
        }
        return ""
    }

    private static func creatorToolFromBinary(url: URL, byteCount: Int) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        let data = fh.readData(ofLength: byteCount)
        try? fh.close()

        let s: String
        if let latin = String(data: data, encoding: .isoLatin1) {
            s = latin
        } else if let utf8 = String(data: data, encoding: .utf8) {
            s = utf8
        } else {
            return nil
        }

        let result = extractCreatorToolFromXMP(s)
        return result.isEmpty ? nil : result
    }

    /// XMP文字列から xmp:CreatorTool の値を抽出する
    /// 要素形式: <xmp:CreatorTool>value</xmp:CreatorTool>
    /// 属性形式: xmp:CreatorTool="value"
    private static func extractCreatorToolFromXMP(_ s: String) -> String {
        // 要素形式
        if let start = s.range(of: "<xmp:CreatorTool>") {
            let tail = String(s[start.upperBound...].prefix(200))
            if let end = tail.range(of: "<") {
                return String(tail[..<end.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
        }
        // 属性形式: xmp:CreatorTool="value"
        if let start = s.range(of: #"xmp:CreatorTool=""#) {
            let tail = String(s[start.upperBound...].prefix(200))
            if let end = tail.range(of: "\"") {
                return String(tail[..<end.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
        }
        return ""
    }

    // MARK: - File Kind

    /// ファイル種別を判定する（拡張子に依存しない・コンテンツベース）
    ///
    /// 判定順：
    /// - A. PDF 構造（先頭 `%PDF-`）
    ///     1. `/AIPDFPrivateData` あり → `kind="PDF"`, isIllustratorFile=true（Illustrator編集機能保持PDF）
    ///     2. AIMetaData オブジェクトあり → `kind="Ai"`, isIllustratorFile=true（通常の.ai形式）
    ///     3. それ以外 → `kind="PDF"`（通常PDF）
    /// - B. PostScript セクション（生PSヘッダ or バイナリEPSラッパ後のPS）
    ///     - 1行目に `EPSF-` を含む → `kind="EPS"`、`%%Creator:` で Illustrator/Photoshop を判定
    ///     - 含まない（純PSの旧.ai） → Illustrator マーカーがあれば `kind="Ai"`, isIllustratorFile=true
    /// - C. PSD ネイティブ（先頭4B = `8BPS`） → `kind="PSD"`
    /// - D. それ以外 → `kind=""`
    ///
    /// Finder Creator/FileType（ART5/8BIM）は最初に短絡させる（クラシックMac互換）。
    static func getFileKind(fc: inout AiFileModel, pdfXref: (root: Int, offsets: [Int: UInt64])?) -> String {
        // Finder 情報での早期判定（クラシックMac互換）
        if fc.finderInfoCreator == "ART5" {
            if ["TEXT", "PDF ", "AITm"].contains(fc.finderInfoFileType) {
                fc.isIllustratorFile = true
                if fc.finderInfoFileType == "AITm" { fc.isTemplate = true }
                return epsHeaderCheck(url: fc.url) ? "EPS" : "Ai"
            } else if ["EPSF", "EPSP"].contains(fc.finderInfoFileType) {
                fc.isIllustratorFile = true
                return "EPS"
            }
        } else if fc.finderInfoCreator == "8BIM" && fc.finderInfoFileType == "EPSF" {
            fc.isIllustratorFile = false
            return "EPS"
        }

        // A. PDF 構造
        if let xref = pdfXref {
            // A-1. /AIPDFPrivateData → Illustrator編集機能保持PDF
            if isAIPDFFormat(url: fc.url) {
                fc.isIllustratorFile = true
                return "PDF"
            }
            // A-2. AIMetaData → 通常の.ai形式（PDF）
            if let fh = try? FileHandle(forReadingFrom: fc.url) {
                defer { try? fh.close() }
                if traverseToAIMetaDataObj(root: xref.root, offsets: xref.offsets, fh: fh) != nil {
                    fc.isIllustratorFile = true
                    // 先頭2KBのdc:formatで本物の.aitか判定（バイト列検索のみ・XMLパースなし）
                    fc.isTemplate = isIllustratorTemplateFormat(url: fc.url)
                    return "Ai"
                }
            }
            // A-3. それ以外 → 通常PDF
            return "PDF"
        }

        // B. PostScript セクション
        if let ps = epsReadPSHeader(url: fc.url, length: 16384) {
            let firstLine = ps.split(whereSeparator: { $0 == "\r" || $0 == "\n" }).first.map(String.init) ?? ""
            if firstLine.contains("%!PS-Adobe-") {
                let isIllustratorPS = ps.contains("%%AI8_CreatorVersion:")
                    || ps.contains("%%Creator: Adobe Illustrator")
                    || ps.contains("%%Creator: (Adobe Illustrator")
                if firstLine.contains("EPSF-") {
                    fc.isIllustratorFile = isIllustratorPS
                    return "EPS"
                }
                if isIllustratorPS {
                    // 旧形式.ai（純PostScript）
                    fc.isIllustratorFile = true
                    return "Ai"
                }
                // PS だが Illustrator/Photoshop でもない → 不明にフォールスルー
            }
        }

        // C. PSD ネイティブ（8BPS マジック）
        if let fh = try? FileHandle(forReadingFrom: fc.url) {
            let magic = fh.readData(ofLength: 4)
            try? fh.close()
            if magic.starts(with: Data("8BPS".utf8)) {
                return "PSD"
            }
        }

        // D. 不明
        return ""
    }

    /// ファイル先頭512バイトに "EPSF-" が含まれるか（EPS判定用）
    private static func epsHeaderCheck(url: URL) -> Bool {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return false }
        let header = fh.readData(ofLength: 512)
        try? fh.close()
        return (String(data: header, encoding: .isoLatin1) ?? "").contains("EPSF-")
    }

    /// EPS ファイルの PS 部分先頭を文字列で返す共通ヘルパー
    /// バイナリ EPS（先頭 4 バイト = C5 D0 D3 C6）はオフセットを読んで PS 部分にシークする
    private static func epsReadPSHeader(url: URL, length: Int) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        let magic = fh.readData(ofLength: 4)
        if magic == Data([0xC5, 0xD0, 0xD3, 0xC6]) {
            let offsetData = fh.readData(ofLength: 4)
            guard offsetData.count == 4 else { return nil }
            let psOffset = UInt64(offsetData[0])
                         | UInt64(offsetData[1]) << 8
                         | UInt64(offsetData[2]) << 16
                         | UInt64(offsetData[3]) << 24
            try? fh.seek(toOffset: psOffset)
        } else {
            try? fh.seek(toOffset: 0)
        }
        return String(data: fh.readData(ofLength: length), encoding: .isoLatin1)
    }

    /// EPS ファイルが Illustrator 製かどうかを PS コメントで判定する
    /// %%Creator: は通常形式と PS 文字列形式（括弧付き）の両方に対応
    private static func epsIsIllustrator(url: URL) -> Bool {
        guard let ps = epsReadPSHeader(url: url, length: 16384) else { return false }
        return ps.contains("%%AI8_CreatorVersion:")
            || ps.contains("%%Creator: Adobe Illustrator")
            || ps.contains("%%Creator: (Adobe Illustrator")
    }

    /// EPS ファイルが Photoshop 製かどうかを PS コメントで判定する
    private static func epsIsPhotoshop(url: URL) -> Bool {
        guard let ps = epsReadPSHeader(url: url, length: 16384) else { return false }
        return ps.contains("%%Creator: Adobe Photoshop")
    }

    /// Photoshop ファイルかどうかを判定する（コンテンツベース）
    private static func isPhotoshopFile(url: URL, kind: String) -> Bool {
        if kind == "PSD" { return true }
        if kind == "EPS" { return epsIsPhotoshop(url: url) }
        return false
    }

    // MARK: - PDF構造ファイル判定

    /// ファイル先頭が %PDF- で始まるかどうか（.ai/.pdf 問わず）
    private static func isPDFBased(url: URL) -> Bool {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return false }
        let header = fh.readData(ofLength: 5)
        try? fh.close()
        return header.starts(with: Data("%PDF-".utf8))
    }

    /// Illustrator編集機能保持PDF判定（.ai偽装検出用）
    /// 通常の .ai は /AIPrivateData、Illustrator編集機能保持PDFは /AIPDFPrivateData を持つ
    private static func isAIPDFFormat(url: URL) -> Bool {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? fh.close() }
        let data = fh.readData(ofLength: 65536)
        return data.range(of: Data("/AIPDFPrivateData".utf8)) != nil
    }

    /// 本物のIllustratorテンプレート（.ait）判定
    /// 先頭2KBのdc:formatを文字列検索するだけ（XMLパースなし）
    /// 本物の.ait: dc:format = application/vnd.adobe.illustrator
    /// .aiを改名:  dc:format = application/pdf
    private static func isIllustratorTemplateFormat(url: URL) -> Bool {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? fh.close() }
        let data = fh.readData(ofLength: 2048)
        return data.range(of: Data("application/vnd.adobe.illustrator".utf8)) != nil
    }

    // MARK: - PDF AIMetaData スキャン
    //
    // Illustratorが保存したPDF構造ファイル（.ai/.pdf）には
    // AIMetaData オブジェクトに %%Creator / %%AI8_CreatorVersion が格納されている。
    //
    // ■ 高速パス（xref解析）
    //   PDF末尾の xref テーブルを読んで全オブジェクトのオフセットを把握し、
    //   Catalog → Pages → Page → PieceInfo/Illustrator → Private → AIMetaData
    //   のチェーンを最小限のシークで辿り、AIMetaData ストリームだけ読む。
    //   大きな XMP ブロブ等を読み飛ばせるため高速。
    //
    // ■ フォールバック（前方スキャン）
    //   xref 解析が失敗した場合（xref ストリーム形式など）は
    //   ファイル全体を Data で読み込んで /AIMetaData を前方検索する。

    // parse() で解析済みの xref を受け取ってバージョンスキャンを行う
    private static func scanVersionCommentsFromPDF(
        xref: (root: Int, offsets: [Int: UInt64]), url: URL, fc: inout AiFileModel
    ) {
        let streamData: Data
        if let d = aiMetaDataStream(xref: xref, url: url) {
            streamData = d
        } else if let d = aiMetaDataStreamForward(url: url) {
            streamData = d
        } else {
            return
        }

        // .eps 拡張子のファイルは kind を維持する（PDF構造の EPS ファイル対応）
        // kind="PDF"（.ai偽装PDF）も上書きしない
        if fc.kind != "EPS" && fc.kind != "PDF" { fc.kind = "Ai" }
        var t = Date()
        let lines = streamData.split(omittingEmptySubsequences: true) { $0 == 0x0D || $0 == 0x0A }
        for line in lines {
            processLineData(line, fc: &fc, t: &t, notDetectEPSCompatibleVer: false)
            if !fc.creator1.isEmpty && !fc.ai8CreatorVersion.isEmpty {
                fc.hasCreator2 = false; return
            }
        }
    }

    // MARK: xref高速パス

    // 解析済み xref を使って AIMetaData ストリームを取得
    private static func aiMetaDataStream(
        xref: (root: Int, offsets: [Int: UInt64]), url: URL
    ) -> Data? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        guard let metaNum = traverseToAIMetaDataObj(root: xref.root,
                                                    offsets: xref.offsets, fh: fh) else { return nil }
        return readPDFObjStream(num: metaNum, offsets: xref.offsets, fh: fh)
    }

    // xref 経由で XMP Metadata オブジェクトから CreatorTool を取得
    // ・Catalog → /Metadata N 0 R → ストリーム先頭 256KB を検索
    // ・見つからなければ "" を返す（大きな XMP を読み続けない）
    private static func getCreatorToolViaXref(
        root: Int, offsets: [Int: UInt64], fh: FileHandle
    ) -> String {
        guard let catStr  = pdfObjStr(num: root, offsets: offsets, fh: fh),
              let metaN   = pdfObjRef("Metadata", in: catStr),
              let metaOff = offsets[metaN] else { return "" }

        // Metadata ストリームのヘッダーだけ読んで /Length と stream 開始位置を取得
        try? fh.seek(toOffset: metaOff)
        let headerData = fh.readData(ofLength: 512)
        let lenKey = Data("/Length ".utf8)
        guard let lkr = headerData.range(of: lenKey) else { return "" }
        let afterLen = headerData[lkr.upperBound...]
        var lenEnd = afterLen.startIndex
        while lenEnd < afterLen.endIndex
            && afterLen[lenEnd] >= UInt8(ascii: "0")
            && afterLen[lenEnd] <= UInt8(ascii: "9") { lenEnd += 1 }
        guard let lenStr = String(data: afterLen[..<lenEnd], encoding: .ascii),
              let totalLen = Int(lenStr), totalLen > 0 else { return "" }

        let streamKey = Data("stream".utf8)
        guard let skr = headerData.range(of: streamKey) else { return "" }
        var bodyIdx = skr.upperBound
        if bodyIdx < headerData.endIndex && headerData[bodyIdx] == 0x0D { bodyIdx += 1 }
        if bodyIdx < headerData.endIndex && headerData[bodyIdx] == 0x0A { bodyIdx += 1 }

        // ストリーム本体を最大 256KB だけ読んで検索
        let bodyFileOffset = metaOff + UInt64(bodyIdx - headerData.startIndex)
        let readLen = min(totalLen, chunkSize)
        try? fh.seek(toOffset: bodyFileOffset)
        let xmpData = fh.readData(ofLength: readLen)

        guard let s = String(data: xmpData, encoding: .utf8)
                   ?? String(data: xmpData, encoding: .isoLatin1) else { return "" }
        return extractCreatorToolFromXMP(s)
    }

    /// xref テーブルを解析してオブジェクト番号→ファイルオフセットの対応表と Root オブジェクト番号を返す
    private static func parsePDFXref(fh: FileHandle) -> (root: Int, offsets: [Int: UInt64])? {
        // 末尾1KBから startxref の値を取得
        guard let fileSize = try? fh.seekToEnd(), fileSize > 0 else { return nil }
        try? fh.seek(toOffset: fileSize - min(1024, fileSize))
        guard let tail = String(data: fh.readData(ofLength: 1024), encoding: .isoLatin1) else { return nil }
        var xrefOff: UInt64?
        for line in tail.components(separatedBy: .newlines).reversed() {
            if let v = UInt64(line.trimmingCharacters(in: .whitespacesAndNewlines)) { xrefOff = v; break }
        }
        guard let startOff = xrefOff else { return nil }

        var offsets = [Int: UInt64]()
        var root: Int?
        var queue = [startOff]
        var seen  = Set<UInt64>()

        while !queue.isEmpty {
            let off = queue.removeFirst()
            guard !seen.contains(off) else { continue }
            seen.insert(off)

            // xref テーブルが 32KB を超える大容量ファイルに対応するため、
            // "trailer" が見つかるまで 32KB ずつ読み足す
            try? fh.seek(toOffset: off)
            var xrefRaw = Data()
            let xrefChunk = 32768
            var trailerFound = false
            while !trailerFound {
                let chunk = fh.readData(ofLength: xrefChunk)
                if chunk.isEmpty { break }
                xrefRaw.append(chunk)
                if xrefRaw.range(of: Data("trailer".utf8)) != nil { trailerFound = true }
                if chunk.count < xrefChunk { break }
            }
            guard let s = String(data: xrefRaw, encoding: .isoLatin1),
                  s.hasPrefix("xref") else { continue }   // xref ストリーム形式は未対応

            // セクション解析: 行イテレータを使って "startObj count" → エントリ群 を処理
            // \r\n を先に \n に正規化してから分割する（\r と \n を個別に分割すると
            // \r\n 行末のエントリが空文字列を挟んでしまいオブジェクトIDがずれるため）
            let sNorm = s.replacingOccurrences(of: "\r\n", with: "\n")
                         .replacingOccurrences(of: "\r", with: "\n")
            var iter = sNorm.components(separatedBy: "\n").makeIterator()
            _ = iter.next()  // "xref" 行をスキップ
            outer: while let line = iter.next() {
                let l = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if l.hasPrefix("trailer") { break }
                let parts = l.split(separator: " ")
                guard parts.count == 2,
                      let secStart = Int(parts[0]), let secCount = Int(parts[1]) else { continue }
                var objID = secStart
                for _ in 0..<secCount {
                    guard let entry = iter.next() else { break outer }
                    let ep = entry.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
                    if ep.count >= 3, ep[2] == "n", let fileOff = UInt64(ep[0]) {
                        offsets[objID] = fileOff
                    }
                    objID += 1
                }
            }

            // trailer から Root と Prev（インクリメンタル更新・線形化対応）を取得
            if let tRange = s.range(of: "trailer") {
                let ts = String(s[tRange.upperBound...])
                if root == nil { root = pdfObjRef("Root", in: ts) }
                if let prev = pdfIntVal("Prev", in: ts) { queue.append(UInt64(prev)) }
            }
        }

        guard let r = root else { return nil }
        return (r, offsets)
    }

    /// Catalog → Pages → Page[0] → PieceInfo/Illustrator → Private → AIMetaData の順に辿り
    /// AIMetaData オブジェクト番号を返す
    private static func traverseToAIMetaDataObj(root: Int, offsets: [Int: UInt64], fh: FileHandle) -> Int? {
        guard let catStr  = pdfObjStr(num: root,     offsets: offsets, fh: fh),
              let pagesN  = pdfObjRef("Pages",        in: catStr),
              let pagesStr = pdfObjStr(num: pagesN,   offsets: offsets, fh: fh),
              let pageN   = pdfFirstKid(in: pagesStr),
              let pageStr  = pdfObjStr(num: pageN,    offsets: offsets, fh: fh),
              let illusN  = pdfObjRef("Illustrator",  in: pageStr),
              let illusStr = pdfObjStr(num: illusN,   offsets: offsets, fh: fh),
              let privN   = pdfObjRef("Private",      in: illusStr),
              let privStr  = pdfObjStr(num: privN,    offsets: offsets, fh: fh),
              let metaN   = pdfObjRef("AIMetaData",   in: privStr) else { return nil }
        return metaN
    }

    /// オブジェクト N のヘッダー部を文字列で返す（最大4KB）
    private static func pdfObjStr(num: Int, offsets: [Int: UInt64], fh: FileHandle) -> String? {
        guard let offset = offsets[num] else { return nil }
        try? fh.seek(toOffset: offset)
        guard let s = String(data: fh.readData(ofLength: 4096), encoding: .isoLatin1),
              s.hasPrefix("\(num) 0 obj") else { return nil }
        return s
    }

    /// オブジェクト N のストリームデータを返す（/Filter があれば zlib 展開）
    private static func readPDFObjStream(num: Int, offsets: [Int: UInt64], fh: FileHandle) -> Data? {
        guard let offset = offsets[num] else { return nil }
        try? fh.seek(toOffset: offset)
        let headerData = fh.readData(ofLength: 8192)

        // /Length 取得
        let lenKey = Data("/Length ".utf8)
        guard let lkr = headerData.range(of: lenKey) else { return nil }
        let afterLen = headerData[lkr.upperBound...]
        var lenEnd = afterLen.startIndex
        while lenEnd < afterLen.endIndex
            && afterLen[lenEnd] >= UInt8(ascii: "0")
            && afterLen[lenEnd] <= UInt8(ascii: "9") { lenEnd += 1 }
        guard let lenStr = String(data: afterLen[..<lenEnd], encoding: .ascii),
              let streamLen = Int(lenStr), streamLen > 0 else { return nil }

        // "stream" マーカーの直後をストリーム本体の先頭とする
        let streamKey = Data("stream".utf8)
        guard let skr = headerData.range(of: streamKey) else { return nil }
        var bodyIdx = skr.upperBound
        if bodyIdx < headerData.endIndex && headerData[bodyIdx] == 0x0D { bodyIdx += 1 }
        if bodyIdx < headerData.endIndex && headerData[bodyIdx] == 0x0A { bodyIdx += 1 }

        let hasFilter = headerData[headerData.startIndex..<skr.lowerBound]
            .range(of: Data("/Filter".utf8)) != nil

        // ストリーム本体をファイルから直接シークして読む
        let bodyFileOffset = offset + UInt64(bodyIdx - headerData.startIndex)
        try? fh.seek(toOffset: bodyFileOffset)
        let raw = fh.readData(ofLength: streamLen)
        guard raw.count == streamLen else { return nil }

        return hasFilter ? zlibInflate(raw) : raw
    }

    // MARK: PDF パースヘルパー

    /// "/Key N 0 R" の N を返す
    private static func pdfObjRef(_ key: String, in s: String) -> Int? {
        guard let re = try? NSRegularExpression(
                pattern: "/" + NSRegularExpression.escapedPattern(for: key) + #"\s+(\d+)\s+0\s+R"#),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return Int(s[r])
    }

    /// "/Kids [ N 0 R ..." の最初の N を返す
    private static func pdfFirstKid(in s: String) -> Int? {
        guard let re = try? NSRegularExpression(pattern: #"/Kids\s*\[\s*(\d+)\s+0\s+R"#),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return Int(s[r])
    }

    /// "/Key N" の整数値 N を返す（Prev など）
    private static func pdfIntVal(_ key: String, in s: String) -> Int? {
        guard let re = try? NSRegularExpression(
                pattern: "/" + NSRegularExpression.escapedPattern(for: key) + #"\s+(\d+)"#),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return Int(s[r])
    }

    // MARK: フォールバック（前方スキャン）

    /// xref 解析が失敗した場合: ファイル全体から /AIMetaData を前方検索してストリームを返す
    private static func aiMetaDataStreamForward(url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let aiMetaKey = Data("/AIMetaData ".utf8)
        guard let keyRange = data.range(of: aiMetaKey) else { return nil }
        let after = data[keyRange.upperBound...]
        guard let spaceIdx = after.firstIndex(where: { $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: ">") }) else { return nil }
        guard let numStr = String(data: after[after.startIndex..<spaceIdx], encoding: .ascii),
              let objNum = Int(numStr) else { return nil }

        let objMarker = Data("\(objNum) 0 obj".utf8)
        guard let objRange = data.range(of: objMarker) else { return nil }
        let objHead = data[objRange.upperBound...]

        guard let lkr = objHead.range(of: Data("/Length ".utf8)) else { return nil }
        let la = objHead[lkr.upperBound...]
        guard let le = la.firstIndex(where: { $0 < UInt8(ascii: "0") || $0 > UInt8(ascii: "9") }),
              let lenStr = String(data: la[..<le], encoding: .ascii),
              let streamLen = Int(lenStr) else { return nil }

        guard let skr = objHead.range(of: Data("stream".utf8)) else { return nil }
        var ss = skr.upperBound
        if ss < objHead.endIndex && objHead[ss] == 0x0D { ss += 1 }
        if ss < objHead.endIndex && objHead[ss] == 0x0A { ss += 1 }
        guard ss + streamLen <= objHead.endIndex else { return nil }
        let raw = Data(objHead[ss..<(ss + streamLen)])

        let hasFilter = objHead[..<skr.lowerBound].range(of: Data("/Filter".utf8)) != nil
        return hasFilter ? zlibInflate(raw) : raw
    }

    // MARK: zlib展開

    // zlib (RFC 1950) の展開
    private static func zlibInflate(_ data: Data) -> Data? {
        guard data.count > 2 else { return nil }
        var result = Data()
        var stream = z_stream()
        var ret = inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard ret == Z_OK else { return nil }
        defer { inflateEnd(&stream) }

        let bufSize = 65536
        var buf = [UInt8](repeating: 0, count: bufSize)
        data.withUnsafeBytes { src in
            stream.next_in  = UnsafeMutablePointer(mutating: src.baseAddress!.assumingMemoryBound(to: Bytef.self))
            stream.avail_in = uInt(data.count)
            repeat {
                buf.withUnsafeMutableBytes { dst in
                    stream.next_out  = dst.baseAddress!.assumingMemoryBound(to: Bytef.self)
                    stream.avail_out = uInt(bufSize)
                }
                ret = inflate(&stream, Z_NO_FLUSH)
                let produced = bufSize - Int(stream.avail_out)
                if produced > 0 { result.append(contentsOf: buf[0..<produced]) }
            } while ret == Z_OK
        }
        return (ret == Z_STREAM_END || ret == Z_OK) ? result : nil
    }

    // MARK: - バージョンコメントスキャン（高速版 v2：FileHandle + seek）
    //
    // FileHandle で 256KB ずつ読み、行を処理。
    // %%BeginData: N が見つかったら seek で N バイト丸ごとスキップ。
    // 初回ディスク読み込み時も大きな埋め込みデータを実際に読まずに飛ばせる。

    private static let chunkSize = 256 * 1024

    // マーカーバイト列（定数）
    private static let markerCreator:    [UInt8] = Array("%%Creator: ".utf8)
    private static let markerAI8:        [UInt8] = Array("%%AI8_CreatorVersion: ".utf8)
    private static let markerBeginData:  [UInt8] = Array("%%BeginData:".utf8)
    private static let markerEndData:    [UInt8] = Array("%%EndData".utf8)

    private static func scanVersionComments(url: URL, fc: inout AiFileModel,
                                            timeLimit: Double, notDetectEPSCompatibleVer: Bool,
                                            startTotal: Date) {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? fh.close() }

        // pending: 読み込み済みだがまだ処理していないバイト列
        // pendingFileStart: pending の先頭バイトがファイル内で何バイト目か
        var pending = Data()
        var pendingFileStart: UInt64 = 0
        var totalRead: UInt64 = 0
        var t = Date()

        mainLoop: while true {
            // タイムアウトチェック
            if Date().timeIntervalSince(startTotal) > timeLimit {
                fc.isTimeOut = true; break
            }

            // EPS で必要情報がそろったら終了
            if fc.kind == "EPS" && !fc.creator1.isEmpty && !fc.ai8CreatorVersion.isEmpty
                && notDetectEPSCompatibleVer { break }

            // pending が空なら次のチャンクを読む
            if pending.isEmpty {
                let chunk = fh.readData(ofLength: chunkSize)
                if chunk.isEmpty { break }
                pending = chunk
                pendingFileStart = totalRead
                totalRead += UInt64(chunk.count)
            }

            // pending から1行分を取り出す
            guard let nlRel = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) else {
                // 改行が見つからない → チャンクを追加して再試行
                let chunk = fh.readData(ofLength: chunkSize)
                if chunk.isEmpty {
                    // ファイル末尾：残りを1行として処理
                    processLinePending(&pending, fc: &fc, t: &t, notDetectEPSCompatibleVer: notDetectEPSCompatibleVer)
                    break
                }
                pending.append(chunk)
                totalRead += UInt64(chunk.count)

                // 巨大な1行（バイナリ混入）なら捨てて次へ
                if pending.count > 4 * 1024 * 1024 {
                    pending.removeAll()
                    pendingFileStart = totalRead
                }
                continue
            }

            let lineEnd = nlRel  // pending 内での改行位置
            let lineLen = lineEnd - pending.startIndex

            // 改行をスキップした次の位置を計算
            var afterNl = pending.index(after: lineEnd)
            if pending[lineEnd] == 0x0D, afterNl < pending.endIndex, pending[afterNl] == 0x0A {
                afterNl = pending.index(after: afterNl)
            }
            // afterNl のファイル内オフセット
            let afterNlFileOffset = pendingFileStart + UInt64(afterNl - pending.startIndex)

            // %% で始まらない行は高速スキップ
            if lineLen < 2 || pending[pending.startIndex] != UInt8(ascii: "%")
                            || pending[pending.index(after: pending.startIndex)] != UInt8(ascii: "%") {
                pending = pending[afterNl...]
                pendingFileStart = afterNlFileOffset
                continue
            }

            // %%BeginData: ByteCount … → seek でスキップ
            if matchesPending(&pending, marker: markerBeginData, lineLen: lineLen) {
                let skipBytes = parseBeginDataByteCount(&pending, markerLen: markerBeginData.count, lineEnd: lineEnd)
                if skipBytes > 0 {
                    let seekTo = afterNlFileOffset + UInt64(skipBytes)
                    try? fh.seek(toOffset: seekTo)
                    totalRead = seekTo
                    pending.removeAll()
                    pendingFileStart = seekTo
                    // %%EndData 行を1チャンク読んで消費
                    let endChunk = fh.readData(ofLength: min(chunkSize, 4096))
                    if !endChunk.isEmpty {
                        totalRead += UInt64(endChunk.count)
                        pending = endChunk
                        // %%EndData を含む行まで読み飛ばす
                        if let edNl = findMarkerLine(in: pending, marker: markerEndData) {
                            var nextLine = pending.index(after: edNl)
                            if pending[edNl] == 0x0D, nextLine < pending.endIndex, pending[nextLine] == 0x0A {
                                nextLine = pending.index(after: nextLine)
                            }
                            pendingFileStart = seekTo + UInt64(nextLine - pending.startIndex)
                            pending = pending[nextLine...]
                        } else {
                            pendingFileStart = totalRead
                            pending.removeAll()
                        }
                    }
                    continue
                }
            }

            // 行を解析
            let lineSlice = pending[..<lineEnd]
            processLineData(lineSlice, fc: &fc, t: &t, notDetectEPSCompatibleVer: notDetectEPSCompatibleVer)

            // Ai: 両方そろったら終了
            if fc.kind == "Ai" && !fc.creator1.isEmpty && !fc.ai8CreatorVersion.isEmpty {
                fc.hasCreator2 = false; break mainLoop
            }
            // EPS: creator2 取得済み or hasCreator2=false で終了
            if fc.kind == "EPS" && !fc.creator1.isEmpty && !fc.creator2.isEmpty { break mainLoop }
            if fc.kind == "EPS" && !fc.creator1.isEmpty && !fc.hasCreator2 { break mainLoop }

            pending = pending[afterNl...]
            pendingFileStart = afterNlFileOffset
        }
    }

    // pending の先頭が marker と一致するか
    private static func matchesPending(_ pending: inout Data, marker: [UInt8], lineLen: Int) -> Bool {
        guard lineLen >= marker.count else { return false }
        for (i, b) in marker.enumerated() {
            if pending[pending.startIndex + i] != b { return false }
        }
        return true
    }

    // %%BeginData: の後の最初の整数（バイト数）を取得
    private static func parseBeginDataByteCount(_ pending: inout Data, markerLen: Int, lineEnd: Data.Index) -> Int {
        var i = pending.startIndex + markerLen
        while i < lineEnd && pending[i] == UInt8(ascii: " ") { i += 1 }
        var n = 0
        var found = false
        while i < lineEnd {
            let b = pending[i]
            if b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9") {
                n = n * 10 + Int(b - UInt8(ascii: "0"))
                found = true
            } else { break }
            i += 1
        }
        return found ? n : 0
    }

    // Data 内で marker で始まる改行位置を返す（%%EndData 消費用）
    private static func findMarkerLine(in data: Data, marker: [UInt8]) -> Data.Index? {
        var i = data.startIndex
        while i < data.endIndex {
            // 行頭チェック
            if i + marker.count <= data.endIndex {
                var match = true
                for (k, b) in marker.enumerated() {
                    if data[i + k] != b { match = false; break }
                }
                if match {
                    // 行末を探して返す
                    var j = i
                    while j < data.endIndex && data[j] != 0x0A && data[j] != 0x0D { j += 1 }
                    return j < data.endIndex ? j : nil
                }
            }
            // 次の行へ
            while i < data.endIndex && data[i] != 0x0A && data[i] != 0x0D { i += 1 }
            if i < data.endIndex {
                let nl = i
                i = data.index(after: nl)
                if data[nl] == 0x0D, i < data.endIndex, data[i] == 0x0A { i = data.index(after: i) }
            }
        }
        return nil
    }

    // Data スライスを解析してフィールドに格納
    private static func processLineData(_ lineSlice: Data.SubSequence, fc: inout AiFileModel,
                                        t: inout Date, notDetectEPSCompatibleVer: Bool) {
        let lineLen = lineSlice.count
        guard lineLen > 2 else { return }

        // %%Creator:
        if fc.creator1.isEmpty && lineLen > markerCreator.count
            && lineSlice.starts(with: markerCreator) {
            fc.creator1 = extractString(from: lineSlice, offset: markerCreator.count)
            fc.timeCreator1 = Date().timeIntervalSince(t); t = Date()

        // %%AI8_CreatorVersion:
        } else if fc.ai8CreatorVersion.isEmpty && lineLen > markerAI8.count
            && lineSlice.starts(with: markerAI8) {
            fc.ai8CreatorVersion = extractString(from: lineSlice, offset: markerAI8.count)
            fc.timeAI8CreatorVersion = Date().timeIntervalSince(t); t = Date()

            if fc.kind == "EPS" && !fc.creator1.isEmpty {
                if let ver = illustratorMajorVersion(from: fc.creator1), ver < 9 {
                    fc.hasCreator2 = false
                }
            }

        // EPS: 2回目の %%Creator:（互換バージョン）
        } else if fc.kind == "EPS" && !fc.creator1.isEmpty && fc.creator2.isEmpty
            && lineLen > markerCreator.count
            && lineSlice.starts(with: markerCreator) {
            fc.creator2 = extractString(from: lineSlice, offset: markerCreator.count)
            fc.timeCreator2 = Date().timeIntervalSince(t)
            fc.hasCreator2 = true
        }
    }

    // pending 全体を1行として処理（ファイル末尾用）
    private static func processLinePending(_ pending: inout Data, fc: inout AiFileModel,
                                           t: inout Date, notDetectEPSCompatibleVer: Bool) {
        processLineData(pending[...], fc: &fc, t: &t, notDetectEPSCompatibleVer: notDetectEPSCompatibleVer)
    }

    // Data スライスから文字列を取得（UTF-8 → Latin-1 フォールバック）
    // PostScript 文字列形式 "(value)" の外側カッコも除去する
    private static func extractString(from slice: Data.SubSequence, offset: Int) -> String {
        let sub = slice.dropFirst(offset)
        var s = String(data: sub, encoding: .utf8) ?? String(data: sub, encoding: .isoLatin1) ?? ""
        s = s.trimmingCharacters(in: .whitespaces)
        // PS 文字列形式: 先頭 "(" 末尾 ")" を除去
        if s.hasPrefix("(") && s.hasSuffix(")") {
            s = String(s.dropFirst().dropLast())
        }
        return s
    }

    private static func illustratorMajorVersion(from creator1: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: "Illustrator[^ ]* ([.\\d]+)"),
              let match = regex.firstMatch(in: creator1, range: NSRange(creator1.startIndex..., in: creator1)),
              let range = Range(match.range(at: 1), in: creator1) else { return nil }
        return Int(String(creator1[range]).components(separatedBy: ".").first ?? "")
    }

    // MARK: - バージョン判定

    private static func determineVersion(fc: inout AiFileModel) {
        fc.determineCreated = fc.ai8CreatorVersion

        if fc.isIllustratorFile {
            if fc.kind == "EPS" {
                fc.determineSaved = fc.hasCreator2
                    ? versionNumberSuffix(fc.creator2)
                    : versionNumberSuffix(fc.creator1)
            } else {
                fc.determineSaved = versionNumberSuffix(fc.creator1)
            }
        }

        let created = Int(fc.determineCreated.components(separatedBy: ".").first ?? "") ?? 0
        let saved   = Int(fc.determineSaved.components(separatedBy:  ".").first ?? "") ?? 0

        if (17...23).contains(created) && saved == 17 {
            fc.isSavedLowerVersion = false
        } else if created >= 24 && saved == 24 {
            fc.isSavedLowerVersion = false
        } else if created > 0 && saved > 0 {
            fc.isSavedLowerVersion = (created != saved)
        }
    }

    private static func versionNumberSuffix(_ s: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "[.\\d]+$"),
              let match = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let range = Range(match.range, in: s) else { return "" }
        return String(s[range])
    }

    // MARK: - バージョン名変換

    static func versionName(_ ver: String) -> String {
        let parts = ver.components(separatedBy: ".")
        guard let major = Int(parts.first ?? "") else { return ver }
        let minor = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0

        switch major {
        case 1...4:  return parts[0]
        case 5:      return minor > 0 ? "5.\(minor)" : "5"
        case 6...10: return parts[0]
        case 11:     return "CS"
        case 12:     return "CS2"
        case 13:     return "CS3"
        case 14:     return "CS4"
        case 15:     return minor > 0 ? "CS5.\(minor)" : "CS5"
        case 16:     return "CS6"
        case 17:     return "CC"
        case 18:     return "CC 2014"
        case 19:     return "CC 2015"
        case 20:     return "CC 2015.3"
        case 21:     return "CC 2017"
        case 22:     return "CC 2018"
        case 23:     return "CC 2019"
        default:     return major > 23 ? "\(major + 1996)" : ver
        }
    }
}
