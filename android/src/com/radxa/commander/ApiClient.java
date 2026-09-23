package com.radxa.commander;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import org.json.JSONArray;
import org.json.JSONObject;

/** Minimal JSON REST client for the board commander API. No dependencies. */
public class ApiClient {

    private final String base;
    private final String token;

    public ApiClient(String ip, String token) {
        this.base = "http://" + ip.trim() + ":18080";
        this.token = token == null ? "" : token.trim();
    }

    public String getBase() {
        return base;
    }

    public Object request(String method, String path, JSONObject body) throws Exception {
        HttpURLConnection c = null;
        try {
            c = (HttpURLConnection) new URL(base + path).openConnection();
            c.setRequestMethod(method);
            c.setConnectTimeout(8000);
            c.setReadTimeout(15000);
            c.setRequestProperty("Authorization", "Bearer " + token);
            if (body != null) {
                byte[] b = body.toString().getBytes("UTF-8");
                c.setDoOutput(true);
                c.setRequestProperty("Content-Type", "application/json; charset=utf-8");
                c.setRequestProperty("Content-Length", String.valueOf(b.length));
                OutputStream os = c.getOutputStream();
                os.write(b);
                os.flush();
                os.close();
            }
            int code = c.getResponseCode();
            InputStream is = code < 400 ? c.getInputStream() : c.getErrorStream();
            String s = readAll(is);
            if (code == 401) {
                throw new Exception("Token 错误或未授权(401)，请核对板端 token");
            }
            if (code >= 400) {
                String msg = s;
                try {
                    msg = new JSONObject(s).optString("error", s);
                } catch (Exception ignored) {
                    // keep raw body
                }
                throw new Exception("HTTP " + code + ": " + msg);
            }
            s = s.trim();
            if (s.startsWith("[")) {
                return new JSONArray(s);
            }
            return new JSONObject(s);
        } finally {
            if (c != null) {
                c.disconnect();
            }
        }
    }

    public JSONObject get(String path) throws Exception {
        return (JSONObject) request("GET", path, null);
    }

    public JSONArray getArray(String path) throws Exception {
        return (JSONArray) request("GET", path, null);
    }

    public JSONObject put(String path, JSONObject body) throws Exception {
        return (JSONObject) request("PUT", path, body);
    }

    public JSONObject post(String path, JSONObject body) throws Exception {
        return (JSONObject) request("POST", path, body == null ? new JSONObject() : body);
    }

    private static String readAll(InputStream is) throws Exception {
        if (is == null) {
            return "";
        }
        ByteArrayOutputStream bos = new ByteArrayOutputStream();
        byte[] buf = new byte[4096];
        int n;
        while ((n = is.read(buf)) > 0) {
            bos.write(buf, 0, n);
        }
        is.close();
        return new String(bos.toByteArray(), "UTF-8");
    }
}
