package dev.emby.hysteria2;

import org.junit.Test;

public final class LeaseRegistryJUnitTest {
    @Test public void processWideGate() { LeaseRegistryTest.gate(); }
    @Test public void engineOwnershipAndCoreReuse() { LeaseRegistryTest.ownershipAndReuse(); }
    @Test public void configurationProbeAndFailureCleanup() { LeaseRegistryTest.probeAndFailure(); }
    @Test public void releasePendingHandshake() throws Exception { LeaseRegistryTest.pendingCancellation(false); }
    @Test public void detachPendingHandshake() throws Exception { LeaseRegistryTest.pendingCancellation(true); }
    @Test public void concurrentConnectSharesOneCore() throws Exception { LeaseRegistryTest.concurrentConnect(); }
}
