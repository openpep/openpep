// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import CoreText

/// Plain, selectable archival attachments; never uses a configured doctor's identity.
enum SyntheticCardiologyPDF {
  static func render(_ body: String) throws -> Data {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = 4
    paragraph.paragraphSpacing = 7
    let text = NSAttributedString(string: body, attributes: [
      .font: NSFont.systemFont(ofSize: 11),
      .foregroundColor: NSColor.black,
      .paragraphStyle: paragraph,
    ])
    let framesetter = CTFramesetterCreateWithAttributedString(text)
    let data = NSMutableData()
    var page = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
    guard let consumer = CGDataConsumer(data: data),
      let context = CGContext(consumer: consumer, mediaBox: &page, nil)
    else { throw CocoaError(.fileWriteUnknown) }
    let path = CGPath(rect: CGRect(x: 48, y: 70, width: page.width - 96, height: page.height - 118), transform: nil)
    var offset = 0
    var pageNumber = 0
    while offset < text.length {
      let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: offset, length: 0), path, nil)
      let visible = CTFrameGetVisibleStringRange(frame)
      guard visible.length > 0, pageNumber < 100 else { throw CocoaError(.fileWriteUnknown) }
      context.beginPDFPage(nil)
      CTFrameDraw(frame, context)
      pageNumber += 1
      let footer = NSAttributedString(
        string: "OpenPEP | Cardiologia fictícia | Sem assinatura | Página \(pageNumber)",
        attributes: [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.black]
      )
      context.textPosition = CGPoint(x: 48, y: 32)
      CTLineDraw(CTLineCreateWithAttributedString(footer), context)
      context.endPDFPage()
      offset += visible.length
    }
    context.closePDF()
    return data as Data
  }
}
