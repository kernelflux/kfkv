
#ifndef AutoCleanInfo_h
#define AutoCleanInfo_h

#include <queue>

struct AutoCleanInfo {
    NSString *m_key;
    uint64_t m_time;

    AutoCleanInfo(NSString *key, uint64_t time) {
        m_key = key;
        m_time = time;
    }

    AutoCleanInfo(AutoCleanInfo &&src) {
        m_key = src.m_key;
        src.m_key = nil;
        m_time = src.m_time;
    }

    void operator=(AutoCleanInfo &&other) {
        std::swap(m_key, other.m_key);
        std::swap(m_time, other.m_time);
    }

    ~AutoCleanInfo() {
        m_key = nil;
    }

    bool operator<(const AutoCleanInfo &other) const {
        // the oldest m_time comes first
        return m_time > other.m_time;
    }

    // just forbid it for possibly misuse
    explicit AutoCleanInfo(const AutoCleanInfo &other) = delete;
    AutoCleanInfo &operator=(const AutoCleanInfo &other) = delete;
};

typedef std::priority_queue<AutoCleanInfo> AutoCleanInfoQueue_t;

#endif /* AutoCleanInfo_h */
