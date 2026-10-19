package dev.emby.hysteria2;

import android.util.Base64;
import dev.emby.hysteria2.core.hybridge.Hybridge;
import java.security.KeyStore;
import java.security.cert.X509Certificate;
import java.util.LinkedHashMap;
import java.util.Map;
import javax.net.ssl.TrustManager;
import javax.net.ssl.TrustManagerFactory;
import javax.net.ssl.X509TrustManager;
import org.json.JSONObject;

final class GoCore implements LeaseRegistry.Core {
    private final long id;

    GoCore(LeaseRegistry.Config config) throws Exception {
        id = Hybridge.newSession(new JSONObject(config.toMap()).toString());
    }

    @Override public Map<String, Object> connect() throws Exception {
        // Android 14+ roots may live in Conscrypt's APEX rather than Go's Linux
        // search paths. Export the platform trust anchors, never custom/insecure CAs.
        JSONObject value = new JSONObject(Hybridge.connect(id, platformRoots()));
        Map<String, Object> result = new LinkedHashMap<>();
        result.put("host", value.getString("host"));
        result.put("port", value.getInt("port"));
        result.put("username", value.getString("username"));
        result.put("password", value.getString("password"));
        return result;
    }

    @Override public void close() { Hybridge.close(id); }

    private static String platformRoots() throws Exception {
        TrustManagerFactory factory = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm());
        factory.init((KeyStore) null);
        StringBuilder pem = new StringBuilder();
        for (TrustManager manager : factory.getTrustManagers()) {
            if (manager instanceof X509TrustManager) {
                for (X509Certificate certificate : ((X509TrustManager) manager).getAcceptedIssuers()) {
                    pem.append("-----BEGIN CERTIFICATE-----\n");
                    pem.append(Base64.encodeToString(certificate.getEncoded(), Base64.NO_WRAP));
                    pem.append("\n-----END CERTIFICATE-----\n");
                }
            }
        }
        if (pem.length() == 0) throw new LeaseRegistry.Failure("tls_failed");
        return pem.toString();
    }
}
