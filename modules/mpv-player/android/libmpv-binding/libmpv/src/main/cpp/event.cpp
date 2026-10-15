#include <jni.h>

#include <mpv/client.h>

#include "globals.h"
#include "jni_utils.h"
#include "log.h"
#include "file_identity.h"


static void sendPropertyUpdateToJava(JNIEnv *env, MPVInstance* instance, mpv_event_property *prop, jlong entry_id) {
    jstring jprop = env->NewStringUTF(prop->name);
    jstring jvalue = nullptr;
    switch (prop->format) {
    case MPV_FORMAT_NONE:
        env->CallVoidMethod(instance->javaObject, mpv_MPVLib_eventProperty_S, jprop, entry_id);
        break;
    case MPV_FORMAT_FLAG:
        env->CallVoidMethod(instance->javaObject, mpv_MPVLib_eventProperty_Sb, jprop, *(int*)prop->data, entry_id);
        break;
    case MPV_FORMAT_INT64:
        env->CallVoidMethod(instance->javaObject, mpv_MPVLib_eventProperty_Sl, jprop, *(int64_t*)prop->data, entry_id);
        break;
    case MPV_FORMAT_DOUBLE:
        env->CallVoidMethod(instance->javaObject, mpv_MPVLib_eventProperty_Sd, jprop, *(double*)prop->data, entry_id);
        break;
    case MPV_FORMAT_STRING:
        jvalue = env->NewStringUTF(*(const char**)prop->data);
        env->CallVoidMethod(instance->javaObject, mpv_MPVLib_eventProperty_SS, jprop, jvalue, entry_id);
        break;
    default:
        ALOGV("sendPropertyUpdateToJava: Unknown property update format received in callback: %d!", prop->format);
        break;
    }
    if (jprop)
        env->DeleteLocalRef(jprop);
    if (jvalue)
        env->DeleteLocalRef(jvalue);
}

static void sendEventToJava(JNIEnv *env, MPVInstance* instance, int event, jlong entry_id) {
    env->CallVoidMethod(instance->javaObject, mpv_MPVLib_event, event, entry_id);
}

static void sendLogMessageToJava(JNIEnv *env, MPVInstance* instance, mpv_event_log_message *msg) {
    // filter the most obvious cases of invalid utf-8, since Java would choke on it
    const auto invalid_utf8 = [] (unsigned char c) {
        return c == 0xc0 || c == 0xc1 || c >= 0xf5;
    };
    for (int i = 0; msg->text[i]; i++) {
        if (invalid_utf8(static_cast<unsigned char>(msg->text[i])))
            return;
    }

    jstring jprefix = env->NewStringUTF(msg->prefix);
    jstring jtext = env->NewStringUTF(msg->text);

    env->CallVoidMethod(instance->javaObject, mpv_MPVLib_logMessage_SiS,
        jprefix, (jint) msg->log_level, jtext);

    if (jprefix)
        env->DeleteLocalRef(jprefix);
    if (jtext)
        env->DeleteLocalRef(jtext);
}

void *event_thread(void *arg) {
    auto instance = static_cast<MPVInstance*>(arg);
    JNIEnv *env = nullptr;
    acquire_jni_env(instance->vm, &env);
    if (!env) {
        ALOGE("failed to acquire java env");
        return nullptr;
    }

    EventFileIdentity file;
    while (true) {
        mpv_event *mp_event;
        mpv_event_property *mp_property;
        mpv_event_log_message *msg;

        mp_event = mpv_wait_event(instance->mpv, -1.0);

        if (instance->event_thread_request_exit)
            break;

        if (mp_event->event_id == MPV_EVENT_NONE)
            continue;

        switch (mp_event->event_id) {
        case MPV_EVENT_LOG_MESSAGE:
            msg = (mpv_event_log_message*)mp_event->data;
            ALOGV("[%s:%s] %s", msg->prefix, msg->level, msg->text);
            sendLogMessageToJava(env, instance, msg);
            break;
        case MPV_EVENT_PROPERTY_CHANGE:
            mp_property = (mpv_event_property*)mp_event->data;
            sendPropertyUpdateToJava(env, instance, mp_property, file.current());
            break;
        case MPV_EVENT_START_FILE: {
            const auto *start = static_cast<mpv_event_start_file*>(mp_event->data);
            file.start(start ? start->playlist_entry_id : -1);
            sendEventToJava(env, instance, mp_event->event_id, file.current());
            break;
        }
        case MPV_EVENT_END_FILE: {
            const auto *end = static_cast<mpv_event_end_file*>(mp_event->data);
            const int64_t entry_id = end ? end->playlist_entry_id : -1;
            sendEventToJava(env, instance, mp_event->event_id, entry_id);
            file.end(entry_id);
            break;
        }
        case MPV_EVENT_QUEUE_OVERFLOW:
        case MPV_EVENT_SHUTDOWN:
            file.clear();
            sendEventToJava(env, instance, mp_event->event_id, file.current());
            break;
        default:
            ALOGV("event: %s\n", mpv_event_name(mp_event->event_id));
            sendEventToJava(env, instance, mp_event->event_id, file.current());
            break;
        }
    }

    instance->vm->DetachCurrentThread();

    return nullptr;
}
