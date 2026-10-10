import Foundation

extension CLI {
    static func renderHTML(_ s: Stats) -> String {
        let peakHour = s.byHour.enumerated().max(by: { $0.element < $1.element })?.offset ?? 0
        let maxApp = max(1, s.byApp.first?.1 ?? 1)
        let maxHour = max(1, s.byHour.max() ?? 1)
        let maxDay = max(1, s.byDay.map(\.1).max() ?? 1)

        let appRows = s.byApp.map { (app, c) in
            let pct = s.total > 0 ? Double(c) * 100 / Double(s.total) : 0
            return """
            <tr><td>\(esc(app))</td><td data-sort="\(c)">\(c)</td>
            <td data-sort="\(pct)">\(String(format: "%.1f%%", pct))</td>
            <td class="barcell"><span class="bar" style="width:\(c * 100 / maxApp)%"></span></td></tr>
            """
        }.joined()

        let hourBars = (0..<24).map { h in
            let c = s.byHour[h]
            return """
            <div class="hbar" title="\(h):00 · \(c) 条">
              <span style="height:\(c * 100 / maxHour)%"></span><label>\(h)</label>
            </div>
            """
        }.joined()

        let dayRows = s.byDay.map { (d, c) in
            """
            <tr><td>\(esc(d))</td><td data-sort="\(c)">\(c)</td>
            <td class="barcell"><span class="bar" style="width:\(c * 100 / maxDay)%"></span></td></tr>
            """
        }.joined()

        let actionRows = s.actions.isEmpty
            ? "<tr><td colspan=2 class=muted>本期没有规则动作触发</td></tr>"
            : s.actions.map { "<tr><td>\(esc($0.0))</td><td data-sort=\"\($0.1)\">\($0.1)</td></tr>" }.joined()

        return """
        <!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>通知统计 · 近 \(s.days) 天</title>
        <style>
        :root{--bg:#fdfcfa;--fg:#1f2328;--muted:#6b7280;--line:#e5e1da;--accent:#9a3412;--bar:#c2703a}
        *{box-sizing:border-box}
        body{margin:0;background:var(--bg);color:var(--fg);
             font:15px/1.65 -apple-system,"PingFang SC","Helvetica Neue",sans-serif;padding:32px 20px}
        .wrap{max-width:920px;margin:0 auto}
        h1{font-size:26px;margin:0 0 4px} h2{font-size:17px;margin:32px 0 10px;color:var(--accent)}
        .sub{color:var(--muted);margin-bottom:24px;font-size:13px}
        .cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:12px;margin:20px 0}
        .card{border:1px solid var(--line);border-radius:10px;padding:14px 16px;background:#fff}
        .card b{display:block;font-size:26px;font-weight:600;letter-spacing:-.5px}
        .card span{color:var(--muted);font-size:12px}
        table{width:100%;border-collapse:collapse;background:#fff;border:1px solid var(--line);border-radius:8px;overflow:hidden}
        th,td{padding:8px 12px;text-align:left;border-bottom:1px solid var(--line);font-size:14px}
        th{background:#f6f3ee;cursor:pointer;user-select:none;font-weight:600;white-space:nowrap}
        th:hover{background:#efe9e1} th::after{content:" ⇅";color:#bbb;font-size:11px}
        tr:last-child td{border-bottom:none}
        .barcell{width:34%} .bar{display:block;height:9px;background:var(--bar);border-radius:5px}
        .muted{color:var(--muted)}
        .hours{display:flex;gap:3px;align-items:flex-end;height:130px;padding:10px 0;border-bottom:1px solid var(--line)}
        .hbar{flex:1;display:flex;flex-direction:column;justify-content:flex-end;align-items:center;height:100%}
        .hbar span{width:100%;background:var(--bar);border-radius:3px 3px 0 0;min-height:2px}
        .hbar label{font-size:10px;color:var(--muted);margin-top:3px}
        .tablewrap{overflow-x:auto}
        footer{margin-top:36px;color:var(--muted);font-size:12px;border-top:1px solid var(--line);padding-top:12px}
        </style></head><body><div class="wrap">
        <h1>通知统计</h1>
        <div class="sub">近 \(s.days) 天 · 生成于 \(fmtTime(nowUnix())) · 数据源 \(esc(Paths.db.path))</div>

        <div class="cards">
          <div class="card"><b>\(s.total)</b><span>通知总数</span></div>
          <div class="card"><b>\(s.total / max(1, s.days))</b><span>日均</span></div>
          <div class="card"><b>\(peakHour):00</b><span>打扰高峰时段</span></div>
          <div class="card"><b>\(s.unreadOpen)</b><span>至今没点开</span></div>
          <div class="card"><b>\(s.renotified)</b><span>触发二次提醒</span></div>
        </div>

        <h2>谁在打扰我</h2>
        <div class="tablewrap"><table id="apps">
          <thead><tr><th>App</th><th>条数</th><th>占比</th><th>分布</th></tr></thead>
          <tbody>\(appRows)</tbody></table></div>

        <h2>按小时分布</h2>
        <div class="hours">\(hourBars)</div>

        <h2>按天</h2>
        <div class="tablewrap"><table>
          <thead><tr><th>日期</th><th>条数</th><th>分布</th></tr></thead>
          <tbody>\(dayRows)</tbody></table></div>

        <h2>规则动作</h2>
        <div class="tablewrap"><table>
          <thead><tr><th>规则/动作</th><th>次数</th></tr></thead>
          <tbody>\(actionRows)</tbody></table></div>

        <footer>notifhub · 事件驱动通知总线（kqueue，空闲 0% CPU）· 正文超过保留期自动抹除，本页只用元数据统计</footer>
        </div>
        <script>
        document.querySelectorAll('table').forEach(t=>{
          t.querySelectorAll('th').forEach((th,i)=>{
            let asc=false;
            th.addEventListener('click',()=>{
              const tb=t.tBodies[0];
              const rows=[...tb.rows].filter(r=>r.cells.length>1);
              rows.sort((a,b)=>{
                const av=a.cells[i]?.dataset.sort??a.cells[i]?.innerText??'';
                const bv=b.cells[i]?.dataset.sort??b.cells[i]?.innerText??'';
                const an=parseFloat(av), bn=parseFloat(bv);
                if(!isNaN(an)&&!isNaN(bn)) return asc?an-bn:bn-an;
                return asc?String(av).localeCompare(bv,'zh'):String(bv).localeCompare(av,'zh');
              });
              asc=!asc; rows.forEach(r=>tb.appendChild(r));
            });
          });
        });
        </script></body></html>
        """
    }

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
