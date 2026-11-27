package com.wireguard.ksu.status;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.graphics.Color;
import android.os.Build;
import android.text.TextUtils;

import java.io.File;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.Locale;

public final class StatusNotifier {
    public static final String CHANNEL_ID = "wgksu_status_v1";
    public static final int NOTIF_ID = 1001;

    public static final String ACTION_UPDATE = "com.wireguard.ksu.status.UPDATE";
    public static final String ACTION_CANCEL = "com.wireguard.ksu.status.CANCEL";
    public static final String ACTION_START = "com.wireguard.ksu.status.ACTION_START";
    public static final String ACTION_STOP = "com.wireguard.ksu.status.ACTION_STOP";
    public static final String ACTION_RESUME_AUTO = "com.wireguard.ksu.status.ACTION_RESUME_AUTO";

    private static final String PREFS = "wgksu_status_cache";

    private StatusNotifier() {}

    public static void writeActionRequest(Context ctx, String token) {
        try {
            File dir = ctx.getFilesDir();
            if (!dir.exists()) {
                dir.mkdirs();
            }
            File tmp = new File(dir, "action.tmp");
            File req = new File(dir, "action.req");
            try (FileOutputStream fos = new FileOutputStream(tmp)) {
                fos.write((token + "\n").getBytes(StandardCharsets.UTF_8));
                fos.getFD().sync();
            }
            if (!tmp.renameTo(req)) {
                try (FileOutputStream fos = new FileOutputStream(req)) {
                    fos.write((token + "\n").getBytes(StandardCharsets.UTF_8));
                }
                tmp.delete();
            }
        } catch (Throwable ignored) {
        }
    }

    public static void saveState(Context ctx, String state, String iface, String ip4, String ip6,
                                 String mtu, String dns, String net, String blocked) {
        SharedPreferences sp = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        sp.edit()
                .putString("state", nonNull(state))
                .putString("iface", nonNull(iface))
                .putString("ip4", nonNull(ip4))
                .putString("ip6", nonNull(ip6))
                .putString("mtu", nonNull(mtu))
                .putString("dns", nonNull(dns))
                .putString("net", nonNull(net))
                .putString("blocked", nonNull(blocked))
                .apply();
    }

    public static void postTransition(Context ctx, boolean starting) {
        SharedPreferences sp = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        post(ctx,
                starting ? "starting" : "stopping",
                sp.getString("iface", "wg0"),
                sp.getString("ip4", ""),
                sp.getString("ip6", ""),
                sp.getString("mtu", ""),
                sp.getString("dns", ""),
                sp.getString("net", ""),
                "");
    }

    public static void cancel(Context ctx) {
        NotificationManager nm = (NotificationManager) ctx.getSystemService(Context.NOTIFICATION_SERVICE);
        if (nm != null) {
            nm.cancel(NOTIF_ID);
        }
    }

    public static void post(Context ctx, String state, String iface, String ip4, String ip6,
                            String mtu, String dns, String net, String blocked) {
        try {
            File dir = ctx.getFilesDir();
            if (!dir.exists()) dir.mkdirs();
        } catch (Throwable ignored) {
        }
        NotificationManager nm = (NotificationManager) ctx.getSystemService(Context.NOTIFICATION_SERVICE);
        if (nm == null) return;

        String lang = Locale.getDefault().getLanguage();
        boolean isZh = "zh".equalsIgnoreCase(lang);
        boolean isRu = "ru".equalsIgnoreCase(lang);

        ensureChannel(nm, isZh, isRu);

        boolean running = "running".equals(state);
        boolean starting = "starting".equals(state);
        boolean stopping = "stopping".equals(state);
        boolean manualPaused = "paused".equals(state);
        boolean busy = starting || stopping;
        boolean hasBlocked = !TextUtils.isEmpty(blocked);

        String displayIface = TextUtils.isEmpty(iface) ? "wg0" : iface;
        String subText = displayIface;
        if (running && !TextUtils.isEmpty(mtu)) {
            subText = displayIface + " · MTU " + mtu;
        }

        String title;
        String shortText;
        StringBuilder big = new StringBuilder();

        if (starting) {
            title = isZh ? "正在启动…" : (isRu ? "Запуск…" : "Starting…");
            shortText = displayIface;
        } else if (stopping) {
            title = isZh ? "正在停止…" : (isRu ? "Остановка…" : "Stopping…");
            shortText = displayIface;
        } else if (running) {
            String primaryIp = !TextUtils.isEmpty(ip4) ? ip4 : ip6;
            String connWord = isZh ? "已连接" : (isRu ? "Подключено" : "Connected");
            title = TextUtils.isEmpty(primaryIp) ? connWord : (connWord + " · " + primaryIp);

            StringBuilder summary = new StringBuilder();
            if (!TextUtils.isEmpty(dns)) {
                summary.append("DNS ").append(dns);
            } else if (!TextUtils.isEmpty(ip6) && !ip6.equals(primaryIp)) {
                summary.append(ip6);
            }
            if (!TextUtils.isEmpty(net)) {
                if (summary.length() > 0) summary.append(" · ");
                summary.append(net);
            }
            shortText = summary.length() > 0 ? summary.toString() : displayIface;

            if (!TextUtils.isEmpty(ip4)) {
                big.append("IPv4: ").append(ip4);
            }
            if (!TextUtils.isEmpty(ip6)) {
                if (big.length() > 0) big.append('\n');
                big.append("IPv6: ").append(ip6);
            }
            if (!TextUtils.isEmpty(dns)) {
                if (big.length() > 0) big.append('\n');
                big.append(isZh ? "隧道 DNS：" : (isRu ? "DNS туннеля: " : "Tunnel DNS: ")).append(dns);
            }
            if (!TextUtils.isEmpty(net)) {
                if (big.length() > 0) big.append('\n');
                big.append(isZh ? "当前网络：" : (isRu ? "Сеть: " : "Network: ")).append(net);
            }
        } else if (manualPaused) {
            title = isZh ? "已手动停止" : (isRu ? "Остановлено вручную" : "Manually stopped");
            String pausedNote = isZh ? "自动启停已暂停" : (isRu ? "Авто-туннель на паузе" : "Auto-Tunnel paused");
            shortText = !TextUtils.isEmpty(net) ? (pausedNote + " · " + net) : pausedNote;
            big.append(pausedNote);
            if (hasBlocked) {
                big.append('\n').append(blocked);
            }
            if (!TextUtils.isEmpty(net)) {
                big.append('\n')
                        .append(isZh ? "当前网络：" : (isRu ? "Сеть: " : "Network: "))
                        .append(net);
            }
        } else {
            if (hasBlocked) {
                title = isZh ? "已按自动规则暂停" : (isRu ? "Пауза по авто-правилу" : "Paused by Auto-Tunnel");
                shortText = blocked;
            } else {
                title = isZh ? "已断开" : (isRu ? "Отключено" : "Disconnected");
                shortText = !TextUtils.isEmpty(net)
                        ? net
                        : (isZh ? "点击启动或打开控制面板" : (isRu ? "Нажмите для запуска или панели" : "Tap to start or open panel"));
            }
            if (hasBlocked && !TextUtils.isEmpty(net)) {
                big.append(blocked).append('\n')
                        .append(isZh ? "当前网络：" : (isRu ? "Сеть: " : "Network: "))
                        .append(net);
            }
        }

        Intent panelIntent = new Intent(ctx, OpenPanelActivity.class);
        panelIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TOP);
        PendingIntent panelPi = PendingIntent.getActivity(
                ctx, 10, panelIntent,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);

        Notification.Builder builder = new Notification.Builder(ctx, CHANNEL_ID)
                .setSmallIcon(running ? R.drawable.ic_stat_wg : R.drawable.ic_stat_wg_off)
                .setContentTitle(title)
                .setContentText(shortText)
                .setSubText(subText)
                .setContentIntent(panelPi)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setShowWhen(false)
                .setLocalOnly(true)
                .setCategory(Notification.CATEGORY_SERVICE)
                .setVisibility(Notification.VISIBILITY_PUBLIC)
                .setColor(resolveAccentColor(ctx, running));

        if (Build.VERSION.SDK_INT >= 29) {
            builder.setAllowSystemGeneratedContextualActions(false);
        }
        if (Build.VERSION.SDK_INT >= 31) {
            builder.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE);
        }

        if (busy) {
            builder.setProgress(0, 0, true);
        } else if (big.length() > 0) {
            builder.setStyle(new Notification.BigTextStyle().bigText(big.toString()));
        }

        if (!busy) {
            Intent toggleIntent = new Intent(ctx, ActionReceiver.class);
            String toggleLabel;
            int reqCode;
            if (running) {
                toggleIntent.setAction(ACTION_STOP);
                reqCode = 20;
                toggleLabel = isZh ? "停止" : (isRu ? "Остановить" : "Stop");
            } else if (manualPaused && hasBlocked) {
                toggleIntent.setAction(ACTION_RESUME_AUTO);
                reqCode = 22;
                toggleLabel = isZh ? "恢复自动" : (isRu ? "Возобновить авто" : "Resume Auto");
            } else {
                toggleIntent.setAction(ACTION_START);
                reqCode = 21;
                toggleLabel = isZh ? "启动" : (isRu ? "Запустить" : "Start");
            }
            PendingIntent togglePi = PendingIntent.getBroadcast(
                    ctx, reqCode, toggleIntent,
                    PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
            builder.addAction(new Notification.Action.Builder(null, toggleLabel, togglePi).build());
        }

        String panelLabel = isZh ? "控制面板" : (isRu ? "Панель" : "Control Panel");
        builder.addAction(new Notification.Action.Builder(null, panelLabel, panelPi).build());

        nm.notify(NOTIF_ID, builder.build());
    }

    private static void ensureChannel(NotificationManager nm, boolean isZh, boolean isRu) {
        String name = isZh ? "WireGuard 运行状态" : (isRu ? "Статус WireGuard" : "WireGuard Status");
        NotificationChannel ch = new NotificationChannel(CHANNEL_ID, name, NotificationManager.IMPORTANCE_DEFAULT);
        ch.setSound(null, null);
        ch.enableVibration(false);
        ch.enableLights(false);
        ch.setShowBadge(false);
        ch.setLockscreenVisibility(Notification.VISIBILITY_PUBLIC);
        nm.createNotificationChannel(ch);
    }

    private static int resolveAccentColor(Context ctx, boolean running) {
        if (Build.VERSION.SDK_INT >= 31) {
            try {
                return ctx.getColor(running
                        ? android.R.color.system_accent1_600
                        : android.R.color.system_neutral2_500);
            } catch (Throwable ignored) {
            }
        }
        return running ? Color.parseColor("#18181B") : Color.parseColor("#71717A");
    }

    private static String nonNull(String s) {
        return s == null ? "" : s;
    }
}
