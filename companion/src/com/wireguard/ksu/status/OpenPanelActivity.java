package com.wireguard.ksu.status;

import android.app.Activity;
import android.os.Bundle;

public final class OpenPanelActivity extends Activity {
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        StatusNotifier.writeActionRequest(this, "open-panel");
        finish();
        overridePendingTransition(0, 0);
    }
}
