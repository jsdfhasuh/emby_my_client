package dev.emby.hysteria2;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;

/** Process-wide policy; independent of Android so fake-core tests use the same code. */
public final class LeaseRegistry {
    public interface Core {
        Map<String, Object> connect() throws Exception;
        void close();
    }

    public interface CoreFactory {
        // Allocation only: implementations must defer blocking work to connect().
        Core create(Config config) throws Exception;
    }

    public static final class Failure extends RuntimeException {
        public final String code;
        public Failure(String code) {
            super(messageFor(code));
            this.code = code;
        }
    }

    public static final class Config {
        public final String host, auth, sni, obfsPassword;
        public final int port;

        private Config(String host, int port, String auth, String sni, String obfsPassword) {
            this.host = host;
            this.port = port;
            this.auth = auth;
            this.sni = sni.isEmpty() ? host : sni;
            this.obfsPassword = obfsPassword == null ? "" : obfsPassword;
        }

        public static Config fromMap(Map<?, ?> map) {
            Set<String> allowed = new HashSet<>();
            java.util.Collections.addAll(allowed, "host", "port", "auth", "sni", "obfsPassword");
            for (Object key : map.keySet()) {
                if (!allowed.contains(key)) throw new Failure("invalid_arguments");
            }
            String host = string(map.get("host"));
            String auth = string(map.get("auth"));
            String sni = string(map.get("sni"));
            Object port = map.get("port");
            Object obfs = map.get("obfsPassword");
            if (!(port instanceof Integer || port instanceof Long) ||
                    ((Number) port).longValue() < 1 || ((Number) port).longValue() > 65535 ||
                    host.isEmpty() || host.length() > 253 || sni.length() > 253 ||
                    auth.isEmpty() || auth.length() > 4096 ||
                    (obfs != null && !(obfs instanceof String))) {
                throw new Failure("invalid_arguments");
            }
            String password = obfs == null ? "" : (String) obfs;
            int bytes = password.getBytes(java.nio.charset.StandardCharsets.UTF_8).length;
            if (bytes > 4096 || (bytes > 0 && bytes < 4)) throw new Failure("invalid_arguments");
            return new Config(host, ((Number) port).intValue(), auth, sni, password);
        }

        public Map<String, Object> toMap() {
            Map<String, Object> value = new LinkedHashMap<>();
            value.put("host", host);
            value.put("port", port);
            value.put("auth", auth);
            value.put("sni", sni);
            if (!obfsPassword.isEmpty()) value.put("obfsPassword", obfsPassword);
            return value;
        }

        @Override public boolean equals(Object other) {
            if (!(other instanceof Config)) return false;
            Config c = (Config) other;
            return port == c.port && host.equals(c.host) && auth.equals(c.auth) &&
                    sni.equals(c.sni) && obfsPassword.equals(c.obfsPassword);
        }

        @Override public int hashCode() { return Objects.hash(host, port, auth, sni, obfsPassword); }
        @Override public String toString() { return "Hysteria2Config[redacted]"; }
    }

    private static final class Lease {
        final String owner, kind;
        Entry entry;
        Lease(String owner, String kind) { this.owner = owner; this.kind = kind; }
    }

    private static final class Entry {
        final Config config;
        final Core core;
        final CountDownLatch ready = new CountDownLatch(1);
        final AtomicBoolean closeOnce = new AtomicBoolean();
        int references;
        boolean closed;
        Map<String, Object> endpoint;
        Failure failure;
        Entry(Config config, Core core) { this.config = config; this.core = core; }
        void close() {
            if (closeOnce.compareAndSet(false, true)) {
                try { core.close(); } catch (RuntimeException | LinkageError ignored) { }
            }
        }
    }

    private final Object lock = new Object();
    private final CoreFactory factory;
    private final Set<String> owners = new HashSet<>();
    private final Map<String, Lease> leases = new HashMap<>();
    private final Map<Config, Entry> entries = new HashMap<>();

    public LeaseRegistry(CoreFactory factory) { this.factory = factory; }

    public void attach(String owner) {
        synchronized (lock) { owners.add(owner); }
    }

    public String acquire(String owner, String scope, String kind) {
        if (scope == null || scope.trim().isEmpty() || scope.length() > 256 ||
                !("download".equals(kind) || "playback".equals(kind) || "configuration".equals(kind))) {
            throw new Failure("invalid_arguments");
        }
        synchronized (lock) {
            requireOwner(owner);
            if ("configuration".equals(kind)) {
                if (!leases.isEmpty()) throw new Failure("busy");
            } else {
                for (Lease lease : leases.values()) {
                    if ("configuration".equals(lease.kind)) throw new Failure("configBusy");
                }
            }
            if (leases.size() >= 4096) throw new Failure("busy");
            String id = UUID.randomUUID().toString();
            leases.put(id, new Lease(owner, kind));
            return id;
        }
    }

    public Map<String, Object> connect(String owner, String id, Config config) {
        Entry entry;
        boolean starter = false;
        synchronized (lock) {
            Lease lease = ownedLease(owner, id);
            if (lease.entry != null) {
                if (!lease.entry.config.equals(config)) throw new Failure("lease_connected");
                entry = lease.entry;
            } else {
                entry = entries.get(config);
                if (entry == null) {
                    try {
                        entry = new Entry(config, factory.create(config));
                    } catch (Exception | LinkageError error) {
                        throw safeFailure(error);
                    }
                    entries.put(config, entry);
                    starter = true;
                }
                entry.references++;
                lease.entry = entry;
            }
        }
        if (starter) {
            try {
                Map<String, Object> endpoint = entry.core.connect();
                synchronized (lock) {
                    if (!entry.closed) entry.endpoint = validateEndpoint(endpoint);
                }
            } catch (Exception | LinkageError error) {
                fail(entry, safeFailure(error));
            } finally {
                entry.ready.countDown();
            }
        }
        try {
            if (!entry.ready.await(20, TimeUnit.SECONDS)) {
                fail(entry, new Failure("timeout"));
                throw new Failure("timeout");
            }
        } catch (InterruptedException error) {
            Thread.currentThread().interrupt();
            throw new Failure("cancelled");
        }
        synchronized (lock) {
            requireOwner(owner);
            Lease lease = leases.get(id);
            if (lease == null || entry.closed) {
                if (entry.failure != null) throw entry.failure;
                throw new Failure("cancelled");
            }
            if (!owner.equals(lease.owner)) throw new Failure("lease_owner");
            if (entry.failure != null) throw entry.failure;
            if (lease.entry != entry || entry.endpoint == null) throw new Failure("cancelled");
            return new LinkedHashMap<>(entry.endpoint);
        }
    }

    private void fail(Entry entry, Failure failure) {
        synchronized (lock) {
            if (!entry.closed) {
                entry.failure = failure;
                entry.closed = true;
                entries.remove(entry.config, entry);
                for (Lease lease : leases.values()) {
                    if (lease.entry == entry) lease.entry = null;
                }
                entry.references = 0;
            }
        }
        entry.ready.countDown();
        entry.close();
    }

    public void release(String owner, String id) {
        Entry closing;
        synchronized (lock) {
            requireOwner(owner);
            Lease lease = leases.get(id);
            if (lease == null) return; // Idempotent release after cancellation.
            if (!owner.equals(lease.owner)) throw new Failure("lease_owner");
            leases.remove(id);
            closing = unreference(lease);
        }
        if (closing != null) closing.close();
    }

    public void detach(String owner) {
        List<Entry> closing = new ArrayList<>();
        synchronized (lock) {
            owners.remove(owner);
            java.util.Iterator<Lease> iterator = leases.values().iterator();
            while (iterator.hasNext()) {
                Lease lease = iterator.next();
                if (owner.equals(lease.owner)) {
                    iterator.remove();
                    Entry entry = unreference(lease);
                    if (entry != null) closing.add(entry);
                }
            }
        }
        for (Entry entry : closing) entry.close();
    }

    // Called under lock. Only leases that actually connected count toward a core.
    private Entry unreference(Lease lease) {
        Entry entry = lease.entry;
        lease.entry = null;
        if (entry != null && --entry.references == 0) {
            entries.remove(entry.config, entry);
            entry.closed = true;
            entry.ready.countDown();
            return entry;
        }
        return null;
    }

    public Map<String, Object> status() {
        synchronized (lock) {
            int downloads = 0, playbacks = 0;
            boolean editing = false, connecting = false;
            for (Lease lease : leases.values()) {
                if ("download".equals(lease.kind)) downloads++;
                else if ("playback".equals(lease.kind)) playbacks++;
                else editing = true;
            }
            for (Entry entry : entries.values()) connecting |= entry.ready.getCount() != 0;
            Map<String, Object> value = new LinkedHashMap<>();
            value.put("downloads", downloads);
            value.put("playbacks", playbacks);
            value.put("editing", editing);
            value.put("cores", entries.size());
            value.put("state", entries.isEmpty() ? "idle" : connecting ? "connecting" : "connected");
            return value;
        }
    }

    private void requireOwner(String owner) {
        if (!owners.contains(owner)) throw new Failure("cancelled");
    }

    private Lease ownedLease(String owner, String id) {
        requireOwner(owner);
        Lease lease = leases.get(id);
        if (lease == null) throw new Failure("invalid_lease");
        if (!owner.equals(lease.owner)) throw new Failure("lease_owner");
        return lease;
    }

    public static String string(Object value) {
        if (!(value instanceof String)) throw new Failure("invalid_arguments");
        return (String) value;
    }

    private static Map<String, Object> validateEndpoint(Map<String, Object> endpoint) {
        if (endpoint == null || !"127.0.0.1".equals(endpoint.get("host")) ||
                !(endpoint.get("port") instanceof Integer) || (Integer) endpoint.get("port") < 1 ||
                (Integer) endpoint.get("port") > 65535 || !(endpoint.get("username") instanceof String) ||
                !(endpoint.get("password") instanceof String) ||
                ((String) endpoint.get("username")).isEmpty() || ((String) endpoint.get("password")).isEmpty()) {
            throw new Failure("connect_failed");
        }
        Map<String, Object> copy = new LinkedHashMap<>();
        for (String key : new String[]{"host", "port", "username", "password"}) copy.put(key, endpoint.get(key));
        return copy;
    }

    public static Failure safeFailure(Throwable error) {
        if (error instanceof Failure) return (Failure) error;
        if (error instanceof LinkageError) return new Failure("unavailable");
        String text = error.getMessage();
        if ("HYSTERIA_CONFIG".equals(text)) return new Failure("invalid_arguments");
        if ("HYSTERIA_CANCELLED".equals(text)) return new Failure("cancelled");
        if ("HYSTERIA_TIMEOUT".equals(text)) return new Failure("timeout");
        if ("HYSTERIA_TLS".equals(text)) return new Failure("tls_failed");
        if ("HYSTERIA_AUTH".equals(text)) return new Failure("auth_failed");
        return new Failure("connect_failed");
    }

    private static String messageFor(String code) {
        switch (code) {
            case "busy": return "Hysteria2 is in use.";
            case "configBusy": return "Hysteria2 configuration is being edited.";
            case "invalid_arguments": return "Invalid Hysteria2 arguments.";
            case "lease_owner": return "Lease belongs to a different engine.";
            case "invalid_lease": return "Unknown Hysteria2 lease.";
            case "lease_connected": return "Lease is already connected to another configuration.";
            case "cancelled": return "Hysteria2 operation cancelled.";
            case "timeout": return "Hysteria2 handshake timed out.";
            case "tls_failed": return "Hysteria2 certificate verification failed.";
            case "auth_failed": return "Hysteria2 authentication failed.";
            case "unavailable": return "Embedded Hysteria2 core is unavailable.";
            default: return "Hysteria2 connection failed.";
        }
    }
}
