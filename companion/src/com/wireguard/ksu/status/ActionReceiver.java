package com.wireguard.ksu.status;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

public final class ActionReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context context, Intent intent) {
        if (intent == null) return;
        String action = intent.getAction();
        if (StatusNotifier.ACTION_START.equals(action)) {
            StatusNotifier.postTransition(context, true);
            StatusNotifier.writeActionRequest(context, "start");
        } else if (StatusNotifier.ACTION_STOP.equals(action)) {
            StatusNotifier.postTransition(context, false);
            StatusNotifier.writeActionRequest(context, "stop");
        } else if (StatusNotifier.ACTION_RESUME_AUTO.equals(action)) {
            StatusNotifier.writeActionRequest(context, "resume-auto");
        }
    }
}
