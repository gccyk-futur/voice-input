import Foundation

/// 词云 HTML 导出：自包含单文件（无 JS、无外链字体/图片），双击即可在浏览器打开。
/// 词的位置直接复用 WordCloudLayout 的结果（绝对定位 span），与 app 内预览一致。
enum WordCloudHTMLExporter {

    static func export(placed: [PlacedWord], canvas: CGSize,
                       sourceCount: Int, generatedAt: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        var spans = ""
        for (rank, p) in placed.enumerated() {
            let color = WordCloudLayout.color(forRank: rank)
            spans += """
                <span class="w" style="left:\(fmt(p.frame.minX))px;top:\(fmt(p.frame.minY))px;\
            font-size:\(fmt(p.fontSize))px;color:\(color);" title="\(escape(p.word)) × \(p.count)">\(escape(p.word))</span>\n
            """
        }

        return """
        <!DOCTYPE html>
        <html lang="zh-CN">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>VoiceKit · 词云</title>
        <style>
          body { margin:0; padding:40px 20px; background:#FAFAF8; color:#1F2937;
                 font-family:-apple-system,"PingFang SC","Microsoft YaHei",sans-serif;
                 display:flex; flex-direction:column; align-items:center; }
          h1 { font-size:20px; font-weight:600; margin:0 0 4px; }
          .meta { font-size:12px; color:#9CA3AF; margin-bottom:24px; }
          .cloud { position:relative; width:\(Int(canvas.width))px; height:\(Int(canvas.height))px;
                   background:#fff; border:1px solid #E5E7EB; border-radius:16px;
                   box-shadow:0 2px 12px rgba(0,0,0,.05); }
          .w { position:absolute; font-weight:600; line-height:1.25; white-space:nowrap;
               font-family:-apple-system,"PingFang SC","Microsoft YaHei",sans-serif; }
        </style>
        </head>
        <body>
        <h1>VoiceKit · 历史词云</h1>
        <div class="meta">\(sourceCount) 条记录 · 生成于 \(formatter.string(from: generatedAt))</div>
        <div class="cloud">
        \(spans)</div>
        </body>
        </html>
        """
    }

    private static func fmt(_ v: Double) -> String {
        String(format: "%.1f", v)
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
