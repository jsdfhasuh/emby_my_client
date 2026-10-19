package dev.emby.hysteria2;

import java.util.LinkedHashMap;
import java.util.Map;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;

/** Runnable with just the JDK: tests production registry, not a second model. */
public final class LeaseRegistryTest {
    static final class FakeCore implements LeaseRegistry.Core {
        final AtomicInteger connects = new AtomicInteger(), closes = new AtomicInteger();
        final CountDownLatch entered = new CountDownLatch(1), proceed = new CountDownLatch(1);
        boolean blocking, failing;
        @Override public Map<String, Object> connect() throws Exception {
            connects.incrementAndGet();
            entered.countDown();
            if (blocking && !proceed.await(3, TimeUnit.SECONDS)) throw new AssertionError("blocked fake");
            if (failing) throw new Exception("sensitive upstream diagnostic");
            Map<String, Object> value = new LinkedHashMap<>();
            value.put("host", "127.0.0.1"); value.put("port", 54321);
            value.put("username", "test-only-user"); value.put("password", "test-only-password");
            return value;
        }
        @Override public void close() { closes.incrementAndGet(); proceed.countDown(); }
    }

    static LeaseRegistry.Config config(String auth) {
        Map<String, Object> value = new LinkedHashMap<>();
        value.put("host", "localhost"); value.put("port", 443); value.put("auth", auth); value.put("sni", "localhost");
        return LeaseRegistry.Config.fromMap(value);
    }
    static void check(boolean value) { if (!value) throw new AssertionError("registry invariant"); }
    static void fails(String code, Runnable work) {
        try { work.run(); throw new AssertionError("expected " + code); }
        catch (LeaseRegistry.Failure failure) { check(code.equals(failure.code)); }
    }
    static LeaseRegistry registry(FakeCore core) {
        LeaseRegistry r = new LeaseRegistry(c -> core); r.attach("ui"); r.attach("background"); return r;
    }

    static void gate() {
        LeaseRegistry r = registry(new FakeCore());
        String download = r.acquire("background", "job", "download");
        fails("busy", () -> r.acquire("ui", "edit", "configuration"));
        String playback = r.acquire("ui", "player", "playback");
        check(r.status().get("downloads").equals(1) && r.status().get("playbacks").equals(1));
        r.release("background", download);
        fails("busy", () -> r.acquire("ui", "edit", "configuration"));
        r.release("ui", playback);
        String edit = r.acquire("ui", "edit", "configuration");
        check(r.status().get("editing").equals(true));
        fails("configBusy", () -> r.acquire("background", "job", "download"));
        fails("configBusy", () -> r.acquire("background", "player", "playback"));
        fails("busy", () -> r.acquire("ui", "edit", "configuration"));
        r.release("ui", edit); r.release("ui", edit);
        check(r.status().get("editing").equals(false));
    }

    static void ownershipAndReuse() {
        FakeCore core = new FakeCore(); LeaseRegistry r = registry(core);
        String first = r.acquire("ui", "one", "download"), second = r.acquire("background", "two", "download");
        fails("lease_owner", () -> r.connect("background", first, config("test")));
        fails("lease_owner", () -> r.release("background", first));
        check(r.connect("ui", first, config("test")).equals(r.connect("background", second, config("test"))));
        r.connect("ui", first, config("test"));
        check(core.connects.get() == 1);
        fails("lease_connected", () -> r.connect("ui", first, config("changed")));
        r.detach("ui"); check(core.closes.get() == 0);
        r.release("background", second); check(core.closes.get() == 1);
        check(r.status().get("cores").equals(0));
        fails("cancelled", () -> r.acquire("ui", "detached", "download"));
    }

    static void probeAndFailure() {
        FakeCore core = new FakeCore(); LeaseRegistry r = registry(core);
        String edit = r.acquire("ui", "probe", "configuration");
        r.connect("ui", edit, config("test")); r.release("ui", edit);
        check(core.closes.get() == 1);
        FakeCore broken = new FakeCore(); broken.failing = true;
        r = registry(broken); final LeaseRegistry f = r;
        String id = r.acquire("ui", "job", "download");
        fails("connect_failed", () -> f.connect("ui", id, config("test")));
        check(broken.closes.get() == 1 && r.status().get("cores").equals(0));
        check(r.status().get("downloads").equals(1));
        r.release("ui", id);
        check(!LeaseRegistry.safeFailure(new Exception("secret")).getMessage().contains("secret"));
    }

    static void pendingCancellation(boolean detach) throws Exception {
        FakeCore core = new FakeCore(); core.blocking = true; LeaseRegistry r = registry(core);
        String id = r.acquire("ui", "probe", "configuration");
        AtomicReference<Throwable> failure = new AtomicReference<>();
        Thread worker = new Thread(() -> {
            try { r.connect("ui", id, config("test")); failure.set(new AssertionError("late endpoint")); }
            catch (LeaseRegistry.Failure expected) { if (!expected.code.equals("cancelled")) failure.set(expected); }
        });
        worker.start(); check(core.entered.await(2, TimeUnit.SECONDS));
        if (detach) r.detach("ui"); else r.release("ui", id);
        worker.join(3000); check(!worker.isAlive() && failure.get() == null);
        check(core.closes.get() == 1 && r.status().get("cores").equals(0));
        check(r.status().get("editing").equals(false));
        r.acquire("background", "next", "configuration");
    }

    static void concurrentConnect() throws Exception {
        FakeCore core = new FakeCore(); core.blocking = true; LeaseRegistry r = registry(core);
        String first = r.acquire("ui", "one", "download"), second = r.acquire("background", "two", "download");
        AtomicReference<Throwable> failure = new AtomicReference<>();
        Thread a = new Thread(() -> { try { r.connect("ui", first, config("test")); } catch (Throwable e) { failure.set(e); } });
        Thread b = new Thread(() -> { try { r.connect("background", second, config("test")); } catch (Throwable e) { failure.set(e); } });
        a.start(); check(core.entered.await(2, TimeUnit.SECONDS)); b.start();
        core.proceed.countDown(); a.join(3000); b.join(3000);
        check(!a.isAlive() && !b.isAlive() && failure.get() == null && core.connects.get() == 1);
        r.detach("ui"); r.detach("background"); check(core.closes.get() == 1);
    }

    public static void main(String[] args) throws Exception {
        gate(); ownershipAndReuse(); probeAndFailure(); pendingCancellation(false);
        pendingCancellation(true); concurrentConnect();
        System.out.println("hysteria2_native_registry=PASSED");
    }
}
