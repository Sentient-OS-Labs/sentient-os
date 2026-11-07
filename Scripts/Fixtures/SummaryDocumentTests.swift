import AppKit
import PDFKit
@main enum SummaryDocumentTests {
 static func main() throws {
  let root=URL(fileURLWithPath:CommandLine.arguments[1]);let pdfURL=root.appendingPathComponent("document.pdf")
  let data=NSMutableData();var media=CGRect(x:0,y:0,width:612,height:792)
  let consumer=CGDataConsumer(data:data as CFMutableData)!
  let context=CGContext(consumer:consumer,mediaBox:&media,nil)!
  for page in 1...12 {
   context.beginPDFPage(nil)
   NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(cgContext:context,flipped:false)
   ("Page \(page): unique evidence \(page == 12 ? "FINAL OFFSCREEN DECISION" : "introduction")" as NSString).draw(at:NSPoint(x:40,y:700),withAttributes:[.font:NSFont.systemFont(ofSize:18)])
   NSGraphicsContext.restoreGraphicsState();context.endPDFPage()
  }
  context.closePDF();try data.write(to:pdfURL)
  let source=SummaryAccessibility.readPDF(at:pdfURL,application:"Fixture")!
  precondition(source.text.contains("FINAL OFFSCREEN DECISION") && source.text.contains("[Page 12]"))
  precondition(!source.truncated && source.image == nil)
  for text in [String(repeating:"many words and lines\n",count:10000),String(repeating:"🙂日本語\n",count:10000),String(repeating:"x",count:100000)] {
   let value=SummaryAccessibility.bounded("START\n"+text+"\nEND",maximumBytes:26000)
   precondition(value.utf8.count<=26000 && value.hasPrefix("START") && value.hasSuffix("END") && !value.contains("\u{FFFD}"))
  }
  precondition(SummaryAccessibility.readPDF(at:URL(string:"https://example.com/document.pdf")!,application:"Fixture")==nil)
  print("PASS: full 12-page PDF, final offscreen evidence, Unicode/long-line bounds, remote-file rejection")
 }
}
