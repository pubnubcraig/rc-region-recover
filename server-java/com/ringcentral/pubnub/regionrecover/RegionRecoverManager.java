package com.ringcentral.pubnub.regionrecover;

import com.pubnub.api.callbacks.PNCallback;
import com.pubnub.api.endpoints.remoteaction.RemoteAction;
import com.pubnub.api.enums.PNStatusCategory;
import com.pubnub.api.models.consumer.PNStatus;
import lombok.Data;
import lombok.NonNull;
import org.jetbrains.annotations.NotNull;

import java.util.ArrayList;
import java.util.List;
import java.util.Timer;
import java.util.TimerTask;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;

public class RegionRecoverManager {

    private final PubNub primaryInstance;
    private final List<PubNub> pubNubs;
    private volatile PubNub currentInstance;
    private Timer timer;
    private final int maxTryBeforeRegionSwitch = 2;


    public RegionRecoverManager(PNConfiguration primaryConfig, PNConfiguration... configs) {
        this.primaryInstance = new PubNub(primaryConfig);
        pubNubs = new ArrayList<>(configs.length);
        for (PNConfiguration config : configs) {
            pubNubs.add(new PubNub(config));
        }
        currentInstance = primaryInstance;
    }

    public <T> void asyncWithFailover(RemoteActionFactory<T> remoteActionFactory, @NotNull PNCallback<T> callback) {
        if (pubNubs.isEmpty()) {
            return;
        }

        TryCounter currentInstanceTryCounter = new TryCounter(maxTryBeforeRegionSwitch);

        remoteActionFactory.create(currentInstance).async((result, status) -> {
            if (status.getCategory().equals(PNStatusCategory.PNTimeoutCategory)) {

                if (!currentInstanceTryCounter.shouldSwitch()) {
                    currentInstanceTryCounter.decrease();
                    status.retry();
                    return;
                }

                //start the timer if this was a call with primaryInstance
                if (currentInstance == primaryInstance) {
                    timer();
                }

                AtomicReference<ResultAndStatus<T>> resultAndStatusAtomicReference = new AtomicReference<>();

                for (PubNub pubNub : pubNubs) {
                    //we know that both currentInstance and primaryInstance are not operational ATM, so we skip them
                    if (pubNub == currentInstance) {
                        continue;
                    }

                    //potentially this is the new currentInstance, until proven wrong
                    this.currentInstance = pubNub;

                    TryCounter tryCounter = new TryCounter(maxTryBeforeRegionSwitch);
                    RemoteAction<T> remoteAction = remoteActionFactory.create(pubNub);
                    final CompletableFuture<PNStatus> future = new CompletableFuture<>();

                    remoteAction.async((newResult, newStatus) -> {
                        resultAndStatusAtomicReference.set(new ResultAndStatus<>(newResult, newStatus));
                        if (!newStatus.isError()) {
                            future.complete(newStatus);
                        }
                        if (!tryCounter.shouldSwitch()) {
                            tryCounter.decrease();
                            newStatus.retry();
                        } else {
                            future.complete(newStatus);
                        }
                    });

                    try {
                        PNStatus returnedStatus = future.get(60_000, TimeUnit.MILLISECONDS);
                        if (!returnedStatus.getCategory().equals(PNStatusCategory.PNTimeoutCategory)) {
                            break; //success, so we can stop iterating
                        }
                    } catch (InterruptedException e) {
                        throw new RuntimeException(e);
                    } catch (ExecutionException e) {
                        //can be ignored
                    } catch (TimeoutException e) {
                        remoteAction.silentCancel();
                        //shouldn't happen. Timeout on the connection should be first
                    }
                }
                ResultAndStatus<T> resultAndStatus = resultAndStatusAtomicReference.get();
                callback.onResponse(resultAndStatus.result, resultAndStatus.status);
            } else {
                callback.onResponse(result, status);
            }
        });
    }

    private void timer() {
        synchronized (this) {
            if (timer != null) timer.cancel();
            timer = new Timer();
            timer.scheduleAtFixedRate(new TimerTask() {
                @Override
                public void run() {
                    primaryInstance.time().async((result, status) -> {
                        if (!status.isError()) {
                            //was able to connect to primaryInstance, so we can anew use primary and cancel timer
                            currentInstance = primaryInstance;
                            timer.cancel();
                        }
                    });
                }
            }, 0, 60 * 1000);
        }
    }

    private static class TryCounter {
        private final AtomicInteger attemptsLeft = new AtomicInteger();

        TryCounter(int attemptsLeft) {
            this.attemptsLeft.set(attemptsLeft);
        }

        void decrease() {
            attemptsLeft.decrementAndGet();
        }

        boolean shouldSwitch() {
            return attemptsLeft.get() <= 0;
        }
    }

    @FunctionalInterface
    interface RemoteActionFactory<T> {
        RemoteAction<T> create(PubNub pubnub);
    }

    @Data
    private static class ResultAndStatus<T> {
        final T result;
        @NonNull
        final PNStatus status;
    }
}
