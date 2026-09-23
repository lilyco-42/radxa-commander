package com.radxa.commander;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.Context;
import android.content.DialogInterface;
import android.content.SharedPreferences;
import android.net.nsd.NsdManager;
import android.net.nsd.NsdServiceInfo;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.text.InputType;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;
import java.util.ArrayList;
import java.util.List;
import org.json.JSONArray;
import org.json.JSONObject;

/** A7A router commander: status / wifi / clients / split / tools. */
public class MainActivity extends Activity {

    private static final String PREF = "commander_pref";

    private final Handler ui = new Handler(Looper.getMainLooper());
    private ApiClient api;
    private String ip = "10.42.0.1";
    private String token = "";

    private TextView deviceLine;
    private TextView connLine;
    private EditText ipField;
    private EditText tokenField;
    private LinearLayout pStatus;
    private LinearLayout pWifi;
    private LinearLayout pClients;
    private LinearLayout pSplit;
    private LinearLayout pTools;
    private TextView statusBox;
    private TextView checkBox;
    private EditText wifiSsid;
    private EditText wifiPass;
    private EditText wifiChan;
    private LinearLayout clientsBox;
    private TextView splitNow;
    private LinearLayout splitBox;
    private TextView apState;
    private boolean apEnabled = true;

    private int pad;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        SharedPreferences sp = getSharedPreferences(PREF, MODE_PRIVATE);
        ip = sp.getString("ip", "10.42.0.1");
        token = sp.getString("token", "");

        float d = getResources().getDisplayMetrics().density;
        pad = (int) (12 * d);

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setPadding(pad, pad, pad, pad);
        root.setBackgroundColor(0xFF0F1420);

        TextView title = new TextView(this);
        title.setText("\uD83D\uDE80 A7A 路由器管家");
        title.setTextColor(0xFFE6ECF5);
        title.setTextSize(18);
        root.addView(title);

        deviceLine = new TextView(this);
        deviceLine.setText("未连接");
        deviceLine.setTextColor(0xFF8B98B0);
        deviceLine.setTextSize(12);
        root.addView(deviceLine);

        LinearLayout connRow = new LinearLayout(this);
        connRow.setOrientation(LinearLayout.HORIZONTAL);
        ipField = new EditText(this);
        ipField.setText(ip);
        ipField.setHint("板子IP");
        ipField.setTextSize(12);
        ipField.setTextColor(0xFFE6ECF5);
        connRow.addView(ipField, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
        tokenField = new EditText(this);
        tokenField.setText(token);
        tokenField.setHint("token");
        tokenField.setTextSize(12);
        tokenField.setTextColor(0xFFE6ECF5);
        tokenField.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD);
        connRow.addView(tokenField, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1.4f));
        connRow.addView(mkBtn("连接", new View.OnClickListener() {
            public void onClick(View v) { connect(); }
        }));
        connRow.addView(mkBtn("发现", new View.OnClickListener() {
            public void onClick(View v) { discover(); }
        }));
        root.addView(connRow);

        connLine = new TextView(this);
        connLine.setTextSize(12);
        connLine.setTextColor(0xFF8B98B0);
        root.addView(connLine);

        LinearLayout tabs = new LinearLayout(this);
        tabs.setOrientation(LinearLayout.HORIZONTAL);
        tabs.addView(mkBtn("状态", tabListener("status")));
        tabs.addView(mkBtn("WiFi", tabListener("wifi")));
        tabs.addView(mkBtn("设备", tabListener("clients")));
        tabs.addView(mkBtn("分流", tabListener("split")));
        tabs.addView(mkBtn("工具", tabListener("tools")));
        root.addView(tabs);

        ScrollView sv = new ScrollView(this);
        LinearLayout pages = new LinearLayout(this);
        pages.setOrientation(LinearLayout.VERTICAL);
        pStatus = mkPage();
        pWifi = mkPage();
        pClients = mkPage();
        pSplit = mkPage();
        pTools = mkPage();
        pages.addView(pStatus);
        pages.addView(pWifi);
        pages.addView(pClients);
        pages.addView(pSplit);
        pages.addView(pTools);
        sv.addView(pages);
        root.addView(sv, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f));

        buildStatusPage();
        buildWifiPage();
        buildClientsPage();
        buildSplitPage();
        buildToolsPage();
        showPage("status");

        setContentView(root);
        connect();
    }

    // ---- ui helpers -----------------------------------------------------

    private Button mkBtn(String text, View.OnClickListener l) {
        Button b = new Button(this);
        b.setText(text);
        b.setTextSize(12);
        b.setOnClickListener(l);
        return b;
    }

    private View.OnClickListener tabListener(final String name) {
        return new View.OnClickListener() {
            public void onClick(View v) { showPage(name); }
        };
    }

    private LinearLayout mkPage() {
        LinearLayout p = new LinearLayout(this);
        p.setOrientation(LinearLayout.VERTICAL);
        p.setVisibility(View.GONE);
        return p;
    }

    private void showPage(String name) {
        pStatus.setVisibility("status".equals(name) ? View.VISIBLE : View.GONE);
        pWifi.setVisibility("wifi".equals(name) ? View.VISIBLE : View.GONE);
        pClients.setVisibility("clients".equals(name) ? View.VISIBLE : View.GONE);
        pSplit.setVisibility("split".equals(name) ? View.VISIBLE : View.GONE);
        pTools.setVisibility("tools".equals(name) ? View.VISIBLE : View.GONE);
        if ("status".equals(name)) {
            refreshStatus();
        } else if ("clients".equals(name)) {
            refreshClients();
        } else if ("split".equals(name)) {
            refreshSplit();
        } else if ("tools".equals(name)) {
            refreshAp();
        }
    }

    private TextView mkLabel(String text) {
        TextView t = new TextView(this);
        t.setText(text);
        t.setTextColor(0xFF60A5FA);
        t.setTextSize(13);
        t.setPadding(0, pad / 2, 0, pad / 4);
        return t;
    }

    private TextView mkBody() {
        TextView t = new TextView(this);
        t.setTextColor(0xFFE6ECF5);
        t.setTextSize(13);
        return t;
    }

    private EditText mkInput(String hint) {
        EditText e = new EditText(this);
        e.setHint(hint);
        e.setTextSize(13);
        e.setTextColor(0xFFE6ECF5);
        return e;
    }

    private void toast(final String s) {
        ui.post(new Runnable() {
            public void run() { Toast.makeText(MainActivity.this, s, Toast.LENGTH_SHORT).show(); }
        });
    }

    private void runBg(Runnable r) {
        new Thread(r).start();
    }

    private void setConn(final String s, final boolean ok) {
        ui.post(new Runnable() {
            public void run() {
                connLine.setText(s);
                connLine.setTextColor(ok ? 0xFF4ADE80 : 0xFFF87171);
            }
        });
    }

    // ---- connection -----------------------------------------------------

    private void connect() {
        ip = ipField.getText().toString().trim();
        token = tokenField.getText().toString().trim();
        if (ip.isEmpty()) {
            ip = "10.42.0.1";
        }
        getSharedPreferences(PREF, MODE_PRIVATE).edit()
                .putString("ip", ip).putString("token", token).apply();
        api = new ApiClient(ip, token);
        setConn("连接中…", false);
        runBg(new Runnable() {
            public void run() {
                try {
                    JSONObject hello = api.get("/api/hello");
                    final String v = hello.optString("version", "?");
                    ui.post(new Runnable() {
                        public void run() { deviceLine.setText("已连接 " + ip + "（v" + v + "）"); }
                    });
                    setConn("API 通", true);
                    refreshStatus();
                } catch (final Exception e) {
                    setConn("连接失败：" + e.getMessage(), false);
                }
            }
        });
    }

    private NsdManager.DiscoveryListener discoveryListener;

    private void discover() {
        toast("局域网发现中…");
        try {
            final NsdManager nsd = (NsdManager) getSystemService(Context.NSD_SERVICE);
            if (nsd == null) {
                toast("本机不支持 NSD");
                return;
            }
            if (discoveryListener != null) {
                try { nsd.stopServiceDiscovery(discoveryListener); } catch (Exception ignored) {}
            }
            discoveryListener = new NsdManager.DiscoveryListener() {
                public void onDiscoveryStarted(String t) {}
                public void onDiscoveryStopped(String t) {}
                public void onStartDiscoveryFailed(String t, int e) { toast("发现启动失败"); }
                public void onStopDiscoveryFailed(String t, int e) {}
                public void onServiceFound(final NsdServiceInfo info) {
                    nsd.resolveService(info, new NsdManager.ResolveListener() {
                        public void onResolveFailed(NsdServiceInfo i, int e) {}
                        public void onServiceResolved(NsdServiceInfo i) {
                            final String host = i.getHost() == null ? "" : i.getHost().getHostAddress();
                            if (host.isEmpty()) {
                                return;
                            }
                            runBg(new Runnable() {
                                public void run() {
                                    try {
                                        ApiClient probe = new ApiClient(host, token);
                                        JSONObject hello = probe.get("/api/hello");
                                        if ("radxa-commander".equals(hello.optString("app"))) {
                                            ui.post(new Runnable() {
                                                public void run() {
                                                    ipField.setText(host);
                                                    toast("发现板子：" + host);
                                                    connect();
                                                }
                                            });
                                            try { nsd.stopServiceDiscovery(discoveryListener); }
                                            catch (Exception ignored) {}
                                        }
                                    } catch (Exception ignored) {
                                        // not ours, keep scanning
                                    }
                                }
                            });
                        }
                    });
                }
                public void onServiceLost(NsdServiceInfo info) {}
            };
            nsd.discoverServices("_http._tcp.", NsdManager.PROTOCOL_DNS_SD, discoveryListener);
        } catch (Exception e) {
            toast("发现失败：" + e.getMessage());
        }
    }

    // ---- pages ----------------------------------------------------------

    private void buildStatusPage() {
        pStatus.addView(mkLabel("运行状态"));
        statusBox = mkBody();
        pStatus.addView(statusBox);
        LinearLayout row = new LinearLayout(this);
        row.setOrientation(LinearLayout.HORIZONTAL);
        row.addView(mkBtn("↻ 刷新", new View.OnClickListener() {
            public void onClick(View v) { refreshStatus(); }
        }));
        row.addView(mkBtn("🩺 一键体检", new View.OnClickListener() {
            public void onClick(View v) { runCheck(); }
        }));
        pStatus.addView(row);
        pStatus.addView(mkLabel("体检结果"));
        checkBox = mkBody();
        pStatus.addView(checkBox);
    }

    private void refreshStatus() {
        if (api == null) {
            return;
        }
        statusBox.setText("加载中…");
        runBg(new Runnable() {
            public void run() {
                try {
                    final JSONObject s = api.get("/api/status");
                    final StringBuilder sb = new StringBuilder();
                    sb.append("板子：").append(s.optString("board")).append("\n");
                    sb.append("在线：").append(fmtUptime(s.optLong("uptime_s"))).append("\n");
                    sb.append("负载：").append(s.optDouble("load1")).append("\n");
                    JSONObject mem = s.optJSONObject("mem_mb");
                    if (mem != null) {
                        sb.append("内存：可用 ").append(mem.optInt("MemAvailable"))
                          .append(" / ").append(mem.optInt("MemTotal")).append(" MB\n");
                    }
                    if (!s.isNull("temp_c")) {
                        sb.append("温度：").append(s.optDouble("temp_c")).append(" ℃\n");
                    }
                    JSONObject wan = s.optJSONObject("wan");
                    if (wan != null) {
                        sb.append("WAN：").append(wan.optString("iface"))
                          .append(" ").append(wan.optString("ip")).append("\n");
                    }
                    JSONObject ap = s.optJSONObject("ap");
                    if (ap != null) {
                        sb.append("热点：").append(ap.optString("ssid"))
                          .append(" ch").append(ap.optString("channel")).append("\n");
                    }
                    JSONObject mm = s.optJSONObject("mihomo");
                    if (mm != null) {
                        sb.append("分流：").append(mm.optBoolean("active") ? "运行中" : "未运行")
                          .append("，当前节点 ").append(mm.optString("group_now"));
                    }
                    final String out = sb.toString();
                    ui.post(new Runnable() {
                        public void run() { statusBox.setText(out); }
                    });
                } catch (final Exception e) {
                    ui.post(new Runnable() {
                        public void run() { statusBox.setText("失败：" + e.getMessage()); }
                    });
                }
            }
        });
    }

    private String fmtUptime(long s) {
        long d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60;
        if (d > 0) {
            return d + "天" + h + "时";
        }
        if (h > 0) {
            return h + "时" + m + "分";
        }
        return m + "分";
    }

    private void runCheck() {
        if (api == null) {
            return;
        }
        checkBox.setText("体检中…");
        runBg(new Runnable() {
            public void run() {
                try {
                    final JSONObject c = api.get("/api/check");
                    final StringBuilder sb = new StringBuilder();
                    sb.append(item("热点在线", c.optBoolean("ap_active")));
                    sb.append(item("IP 转发", c.optBoolean("ip_forward")));
                    JSONObject tx = c.optJSONObject("tx_delay");
                    if (tx != null) {
                        sb.append(item("网口 tx-delay=" + tx.optString("value"), tx.optBoolean("ok")));
                    }
                    sb.append(item("NAT 出口", c.optBoolean("nat_masquerade")));
                    sb.append(item("TCP 透明劫持", c.optBoolean("redirect_tcp")));
                    sb.append(item("DNS 劫持", c.optBoolean("dns_hijack_udp")));
                    sb.append(item("mihomo", c.optBoolean("mihomo_active")));
                    sb.append(item("dnsmasq", c.optBoolean("dnsmasq_running")));
                    final String out = sb.toString();
                    ui.post(new Runnable() {
                        public void run() { checkBox.setText(out); }
                    });
                } catch (final Exception e) {
                    ui.post(new Runnable() {
                        public void run() { checkBox.setText("失败：" + e.getMessage()); }
                    });
                }
            }
        });
    }

    private String item(String name, boolean ok) {
        return (ok ? "✅ " : "❌ ") + name + "\n";
    }

    private void buildWifiPage() {
        pWifi.addView(mkLabel("WiFi 设置（应用后手机会断开，需重连）"));
        wifiSsid = mkInput("SSID");
        pWifi.addView(wifiSsid);
        wifiPass = mkInput("密码（≥8位）");
        wifiPass.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD);
        pWifi.addView(wifiPass);
        wifiChan = mkInput("信道 1-13");
        wifiChan.setInputType(InputType.TYPE_CLASS_NUMBER);
        pWifi.addView(wifiChan);
        LinearLayout row = new LinearLayout(this);
        row.setOrientation(LinearLayout.HORIZONTAL);
        row.addView(mkBtn("读取当前", new View.OnClickListener() {
            public void onClick(View v) { loadWifi(); }
        }));
        row.addView(mkBtn("应用", new View.OnClickListener() {
            public void onClick(View v) { confirmApplyWifi(); }
        }));
        pWifi.addView(row);
        loadWifi();
    }

    private void loadWifi() {
        if (api == null) {
            return;
        }
        runBg(new Runnable() {
            public void run() {
                try {
                    final JSONObject w = api.get("/api/wifi");
                    ui.post(new Runnable() {
                        public void run() {
                            wifiSsid.setText(w.optString("ssid"));
                            wifiPass.setText(w.optString("password"));
                            wifiChan.setText(String.valueOf(w.optInt("channel")));
                        }
                    });
                } catch (final Exception e) {
                    toast("读取失败：" + e.getMessage());
                }
            }
        });
    }

    private void confirmApplyWifi() {
        new AlertDialog.Builder(this)
                .setTitle("应用 WiFi 设置？")
                .setMessage("热点头会重建，手机将断开并需要用新密码重连。继续吗？")
                .setPositiveButton("应用", new DialogInterface.OnClickListener() {
                    public void onClick(DialogInterface d, int w) { applyWifi(); }
                })
                .setNegativeButton("取消", null)
                .show();
    }

    private void applyWifi() {
        if (api == null) {
            return;
        }
        final String ssid = wifiSsid.getText().toString().trim();
        final String pass = wifiPass.getText().toString();
        final String chan = wifiChan.getText().toString().trim();
        if (!pass.isEmpty() && pass.length() < 8) {
            toast("密码至少 8 位");
            return;
        }
        toast("应用中，热点将重启…");
        runBg(new Runnable() {
            public void run() {
                try {
                    JSONObject body = new JSONObject();
                    body.put("ssid", ssid);
                    if (!pass.isEmpty()) {
                        body.put("password", pass);
                    }
                    if (!chan.isEmpty()) {
                        body.put("channel", Integer.parseInt(chan));
                    }
                    final JSONObject w = api.put("/api/wifi", body);
                    ui.post(new Runnable() {
                        public void run() {
                            wifiSsid.setText(w.optString("ssid"));
                            wifiChan.setText(String.valueOf(w.optInt("channel")));
                        }
                    });
                    toast("已应用，请用新配置重连 WiFi");
                } catch (final Exception e) {
                    toast("应用失败：" + e.getMessage());
                }
            }
        });
    }

    private void buildClientsPage() {
        pClients.addView(mkLabel("在线设备"));
        clientsBox = new LinearLayout(this);
        clientsBox.setOrientation(LinearLayout.VERTICAL);
        pClients.addView(clientsBox);
        LinearLayout row = new LinearLayout(this);
        row.setOrientation(LinearLayout.HORIZONTAL);
        row.addView(mkBtn("↻ 刷新", new View.OnClickListener() {
            public void onClick(View v) { refreshClients(); }
        }));
        pClients.addView(row);
    }

    private void refreshClients() {
        if (api == null) {
            return;
        }
        runBg(new Runnable() {
            public void run() {
                try {
                    final JSONArray arr = api.getArray("/api/clients");
                    final List<JSONObject> list = new ArrayList<JSONObject>();
                    for (int i = 0; i < arr.length(); i++) {
                        list.add(arr.getJSONObject(i));
                    }
                    ui.post(new Runnable() {
                        public void run() { renderClients(list); }
                    });
                } catch (final Exception e) {
                    toast("读取失败：" + e.getMessage());
                }
            }
        });
    }

    private void renderClients(List<JSONObject> list) {
        clientsBox.removeAllViews();
        if (list.isEmpty()) {
            TextView t = mkBody();
            t.setText("暂无设备");
            clientsBox.addView(t);
            return;
        }
        for (final JSONObject c : list) {
            LinearLayout row = new LinearLayout(this);
            row.setOrientation(LinearLayout.HORIZONTAL);
            TextView t = new TextView(this);
            String host = c.optString("hostname");
            if (host.isEmpty()) {
                host = c.optString("mac");
            }
            t.setText(host + "\n" + c.optString("ip") + " · " + c.optString("mac")
                    + " · " + c.optString("state"));
            t.setTextColor(0xFFE6ECF5);
            t.setTextSize(12);
            row.addView(t, new LinearLayout.LayoutParams(0,
                    ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
            final boolean blocked = c.optBoolean("blocked");
            row.addView(mkBtn(blocked ? "解禁" : "拉黑", new View.OnClickListener() {
                public void onClick(View v) { setBlocked(c.optString("mac"), !blocked); }
            }));
            clientsBox.addView(row);
        }
    }

    private void setBlocked(final String mac, final boolean block) {
        if (api == null) {
            return;
        }
        runBg(new Runnable() {
            public void run() {
                try {
                    JSONObject body = new JSONObject();
                    body.put("mac", mac);
                    api.post(block ? "/api/clients/block" : "/api/clients/unblock", body);
                    toast(block ? "已拉黑 " + mac : "已解禁 " + mac);
                    refreshClients();
                } catch (final Exception e) {
                    toast("操作失败：" + e.getMessage());
                }
            }
        });
    }

    private void buildSplitPage() {
        pSplit.addView(mkLabel("智能分流 · 当前节点"));
        splitNow = mkBody();
        pSplit.addView(splitNow);
        splitBox = new LinearLayout(this);
        splitBox.setOrientation(LinearLayout.VERTICAL);
        pSplit.addView(splitBox);
        LinearLayout row = new LinearLayout(this);
        row.setOrientation(LinearLayout.HORIZONTAL);
        row.addView(mkBtn("↻ 刷新", new View.OnClickListener() {
            public void onClick(View v) { refreshSplit(); }
        }));
        pSplit.addView(row);
    }

    private void refreshSplit() {
        if (api == null) {
            return;
        }
        runBg(new Runnable() {
            public void run() {
                try {
                    final JSONObject g = api.get("/api/split");
                    final String now = g.optString("now");
                    final JSONArray all = g.optJSONArray("all");
                    final List<String> names = new ArrayList<String>();
                    if (all != null) {
                        for (int i = 0; i < all.length(); i++) {
                            names.add(all.optString(i));
                        }
                    }
                    ui.post(new Runnable() {
                        public void run() {
                            splitNow.setText(now);
                            splitBox.removeAllViews();
                            for (final String n : names) {
                                Button b = mkBtn((n.equals(now) ? "● " : "○ ") + n,
                                        new View.OnClickListener() {
                                            public void onClick(View v) { switchNode(n); }
                                        });
                                splitBox.addView(b);
                            }
                        }
                    });
                } catch (final Exception e) {
                    toast("读取失败：" + e.getMessage());
                }
            }
        });
    }

    private void switchNode(final String name) {
        if (api == null) {
            return;
        }
        toast("切换到 " + name + "…");
        runBg(new Runnable() {
            public void run() {
                try {
                    JSONObject body = new JSONObject();
                    body.put("name", name);
                    api.put("/api/split", body);
                    toast("已切换到 " + name);
                    refreshSplit();
                } catch (final Exception e) {
                    toast("切换失败：" + e.getMessage());
                }
            }
        });
    }

    private void buildToolsPage() {
        pTools.addView(mkLabel("工具"));
        apState = mkBody();
        pTools.addView(apState);
        LinearLayout row = new LinearLayout(this);
        row.setOrientation(LinearLayout.HORIZONTAL);
        row.addView(mkBtn("AP 开/关", new View.OnClickListener() {
            public void onClick(View v) { confirmToggleAp(); }
        }));
        row.addView(mkBtn("↻ 重启路由器", new View.OnClickListener() {
            public void onClick(View v) { confirmReboot(); }
        }));
        pTools.addView(row);
        TextView hint = mkBody();
        hint.setText("改 WiFi 密码/SSID 后手机会断开，用新密码重连即可。\n拉黑立即断开该设备。\n切换节点即时生效，无需重连。");
        hint.setTextSize(12);
        pTools.addView(hint);
    }

    private void refreshAp() {
        if (api == null) {
            return;
        }
        runBg(new Runnable() {
            public void run() {
                try {
                    final JSONObject a = api.get("/api/ap");
                    apEnabled = a.optBoolean("enabled", true);
                    final String auto = a.optString("auto", "");
                    final String txt = "AP：" + (apEnabled ? "开" : "关") + "（"
                            + a.optString("ssid") + "）"
                            + ("".equals(auto) ? "" : " · 自动：" + auto);
                    ui.post(new Runnable() {
                        public void run() { apState.setText(txt); }
                    });
                } catch (final Exception e) {
                    toast("读取失败：" + e.getMessage());
                }
            }
        });
    }

    private void confirmToggleAp() {
        final boolean target = !apEnabled;
        new AlertDialog.Builder(this)
                .setTitle(target ? "打开 AP？" : "关闭 AP？")
                .setMessage(target ? "热点将重新广播，设备可重连。"
                        : "热点关闭后所有 WiFi 设备掉线，且无法自行唤醒，需用本 App（经家庭局域网）或定时任务重新打开。继续吗？")
                .setPositiveButton(target ? "打开" : "关闭", new DialogInterface.OnClickListener() {
                    public void onClick(DialogInterface d, int w) { toggleAp(target); }
                })
                .setNegativeButton("取消", null)
                .show();
    }

    private void toggleAp(final boolean target) {
        if (api == null) {
            return;
        }
        runBg(new Runnable() {
            public void run() {
                try {
                    JSONObject body = new JSONObject();
                    body.put("enabled", target);
                    api.put("/api/ap", body);
                    toast(target ? "AP 已打开" : "AP 已关闭");
                    refreshAp();
                } catch (final Exception e) {
                    toast("操作失败：" + e.getMessage());
                }
            }
        });
    }

    private void confirmReboot() {
        new AlertDialog.Builder(this)
                .setTitle("重启路由器？")
                .setMessage("板子将重启，WiFi 中断约 1 分钟。继续吗？")
                .setPositiveButton("重启", new DialogInterface.OnClickListener() {
                    public void onClick(DialogInterface d, int w) { doReboot(); }
                })
                .setNegativeButton("取消", null)
                .show();
    }

    private void doReboot() {
        if (api == null) {
            return;
        }
        runBg(new Runnable() {
            public void run() {
                try {
                    api.post("/api/reboot", null);
                    toast("重启指令已发送");
                } catch (final Exception e) {
                    toast("发送失败：" + e.getMessage());
                }
            }
        });
    }
}
