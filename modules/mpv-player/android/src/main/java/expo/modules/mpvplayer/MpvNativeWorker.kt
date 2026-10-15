package expo.modules.mpvplayer

import java.util.concurrent.Executors

/** Serial native work belongs to one handle; retirement must not wait for a subtitle fetch. */
internal class MpvNativeWorker {
    private val executor = Executors.newSingleThreadExecutor { task ->
        Thread(task, "mpv-load").apply { isDaemon = true }
    }
    private var retired = false

    @Synchronized fun execute(task: () -> Unit) {
        if (!retired) executor.execute(task)
    }

    @Synchronized fun retire(teardown: () -> Unit) {
        if (retired) return
        retired = true
        executor.shutdownNow()
        // mpv's sub-add opens outside the core lock and is aborted by playback
        // teardown. A synchronous command waiting for it cannot own this lane.
        Thread(teardown, "mpv-teardown").apply { isDaemon = true }.start()
    }
}
