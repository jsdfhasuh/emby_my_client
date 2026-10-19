package dev.emby.hysteria2;

import android.os.Handler;
import android.os.Looper;
import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/** Auto-registered by Flutter for both UI and background engines. No Activity. */
public final class Hysteria2Plugin implements FlutterPlugin, MethodChannel.MethodCallHandler {
    private static final LeaseRegistry REGISTRY = new LeaseRegistry(GoCore::new);
    private static final ExecutorService IO = Executors.newFixedThreadPool(4, work -> {
        Thread thread = new Thread(work, "hysteria2-connect");
        thread.setDaemon(true);
        return thread;
    });
    private final Handler main = new Handler(Looper.getMainLooper());
    private volatile String owner;
    private MethodChannel channel;

    @Override public void onAttachedToEngine(FlutterPluginBinding binding) {
        owner = UUID.randomUUID().toString();
        REGISTRY.attach(owner);
        channel = new MethodChannel(binding.getBinaryMessenger(), "dev.emby/hysteria2");
        channel.setMethodCallHandler(this);
    }

    @Override public void onDetachedFromEngine(FlutterPluginBinding binding) {
        String detached = owner;
        owner = null;
        if (channel != null) channel.setMethodCallHandler(null);
        channel = null;
        if (detached != null) REGISTRY.detach(detached);
    }

    @Override public void onMethodCall(MethodCall call, MethodChannel.Result result) {
        final String caller = owner;
        if (caller == null) {
            error(result, new LeaseRegistry.Failure("cancelled"));
            return;
        }
        try {
            if ("status".equals(call.method)) {
                result.success(REGISTRY.status());
                return;
            }
            if (!(call.arguments instanceof Map)) throw new LeaseRegistry.Failure("invalid_arguments");
            Map<?, ?> args = (Map<?, ?>) call.arguments;
            switch (call.method) {
                case "acquire":
                    result.success(REGISTRY.acquire(caller, LeaseRegistry.string(args.get("scope")),
                            LeaseRegistry.string(args.get("kind"))));
                    break;
                case "release":
                    REGISTRY.release(caller, LeaseRegistry.string(args.get("leaseId")));
                    result.success(null);
                    break;
                case "connect":
                    String leaseId = LeaseRegistry.string(args.get("leaseId"));
                    if (!(args.get("config") instanceof Map)) throw new LeaseRegistry.Failure("invalid_arguments");
                    LeaseRegistry.Config config = LeaseRegistry.Config.fromMap((Map<?, ?>) args.get("config"));
                    IO.execute(() -> {
                        try {
                            Map<String, Object> endpoint = REGISTRY.connect(caller, leaseId, config);
                            main.post(() -> {
                                if (caller.equals(owner)) result.success(endpoint);
                            });
                        } catch (Exception | LinkageError failure) {
                            LeaseRegistry.Failure safe = LeaseRegistry.safeFailure(failure);
                            main.post(() -> {
                                if (caller.equals(owner)) error(result, safe);
                            });
                        }
                    });
                    break;
                default:
                    result.notImplemented();
            }
        } catch (Exception | LinkageError failure) {
            error(result, LeaseRegistry.safeFailure(failure));
        }
    }

    private static void error(MethodChannel.Result result, LeaseRegistry.Failure failure) {
        // Neither upstream exception text nor config/URI/credentials crosses channels.
        result.error(failure.code, failure.getMessage(), null);
    }
}
