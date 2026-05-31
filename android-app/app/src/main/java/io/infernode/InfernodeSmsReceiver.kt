package io.infernode

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.provider.Telephony
import android.util.Log

/**
 * INFR-182 SMS-receive slice.
 *
 * Manifest-declared receiver for `android.provider.Telephony.SMS_RECEIVED`.
 * Extracts the PDU array, concatenates multi-part messages by sender,
 * formats the canonical devphone wire record
 *
 *     from <sender> <timestamp>\n<body>\n
 *
 * (matches the parser in `appl/veltro/sources/sms.b:227`), and pushes
 * each record to native via [InfernodePhoneBridge.postSms]. devphone's
 * `phonebridge_post_sms` then fans the bytes out to every open reader
 * of `/phone/sms`.
 *
 * SMS_RECEIVED is one of the implicit-broadcast exemptions on API 26+,
 * so this still fires when the Activity isn't running. The bridge will
 * be loaded on-demand if it isn't already in the process — but in
 * practice the Activity is the only entry point and InfernodePhoneBridge
 * is already loaded once SDL boots. If the bridge isn't loaded, the
 * native call will throw `UnsatisfiedLinkError` and we drop the record;
 * better to drop than to crash the receiver. The user will see the
 * SMS in the system Messages app regardless.
 */
class InfernodeSmsReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Telephony.Sms.Intents.SMS_RECEIVED_ACTION) return

        // getMessagesFromIntent stitches multi-part PDUs together
        // already on the sending side; we still group by sender below
        // for safety against carriers that don't honour that contract.
        val msgs = Telephony.Sms.Intents.getMessagesFromIntent(intent) ?: return
        if (msgs.isEmpty()) return

        // Concatenate body fragments under their originating address.
        // The PDU array is already in delivery order; a single SMS is
        // up to seven concatenated fragments, all from the same sender.
        val bySender = LinkedHashMap<String, StringBuilder>()
        var earliestTs = Long.MAX_VALUE
        for (m in msgs) {
            val from = m.displayOriginatingAddress ?: m.originatingAddress ?: continue
            val text = m.displayMessageBody ?: m.messageBody ?: ""
            bySender.getOrPut(from) { StringBuilder() }.append(text)
            if (m.timestampMillis < earliestTs) earliestTs = m.timestampMillis
        }

        val ts = if (earliestTs == Long.MAX_VALUE) System.currentTimeMillis() else earliestTs

        for ((sender, body) in bySender) {
            val record = "from $sender $ts\n${body}\n"
            try {
                InfernodePhoneBridge.postSms(record)
                Log.i(TAG, "received SMS from=$sender bytes=${record.length}")
            } catch (ule: UnsatisfiedLinkError) {
                // libemu.so not loaded in this process — Activity isn't
                // up. Surface the drop so we know it happened, but don't
                // crash the receiver.
                Log.w(TAG, "drop: postSms native not linked (Activity not up?)")
            } catch (t: Throwable) {
                Log.w(TAG, "drop: ${t.javaClass.simpleName} — ${t.message}")
            }
        }
    }

    companion object {
        private const val TAG = "InfernodeSmsReceiver"
    }
}
