package com.wireguard.ksu.status;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.text.TextUtils;
import android.widget.Toast;

public final class StatusReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context context, Intent intent) {
        if (intent == null) return;
        String action = intent.getAction();
        if (StatusNotifier.ACTION_CANCEL.equals(action)) {
            StatusNotifier.cancel(context);
            return;
        }
        if (StatusNotifier.ACTION_UPDATE.equals(action)) {
            String state = intent.getStringExtra("state");
            String iface = intent.getStringExtra("iface");
            String ip4 = intent.getStringExtra("ip4");
            String ip6 = intent.getStringExtra("ip6");
            String mtu = intent.getStringExtra("mtu");
            String dns = intent.getStringExtra("dns");
            String net = intent.getStringExtra("net");
            String blocked = intent.getStringExtra("blocked");
            String toast = intent.getStringExtra("toast");

            StatusNotifier.saveState(context, state, iface, ip4, ip6, mtu, dns, net, blocked);
            StatusNotifier.post(context, state, iface, ip4, ip6, mtu, dns, net, blocked);

            if (!TextUtils.isEmpty(toast)) {
                Toast.makeText(context.getApplicationContext(), toast, Toast.LENGTH_LONG).show();
            }
        }
    }
}
