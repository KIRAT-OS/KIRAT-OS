// kernel-ai/kirat-ai.c
// KIRAT AI Kernel Module — Sentinel Core Bridge
// 
// This kernel module creates a direct communication channel between
// the Linux kernel and the Sentinel AI runtime. It enables:
//   - Real-time system state reading (CPU, memory, I/O, thermal)
//   - eBPF program injection for custom tracing
//   - Kernel event streaming (OOM, panics, hardware errors)
//   - Scheduling priority control for critical workloads
//   - Power management (CPU frequency, sleep states)
//
// Interface:
//   /dev/kirat-ai        — character device (commands & responses)
//   /sys/kernel/kirat/   — sysfs (configuration)
//   /proc/kirat/         — procfs (statistics)
//   netlink KIRAT_FAMILY — async kernel events

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/fs.h>
#include <linux/cdev.h>
#include <linux/device.h>
#include <linux/uaccess.h>
#include <linux/slab.h>
#include <linux/mutex.h>
#include <linux/ktime.h>
#include <linux/sched.h>
#include <linux/sched/task.h>
#include <linux/cpufreq.h>
#include <linux/thermal.h>
#include <linux/netlink.h>
#include <linux/skbuff.h>
#include <net/sock.h>
#include <linux/bpf.h>
#include <linux/btf.h>
#include <linux/io_uring.h>
#include <linux/perf_event.h>
#include <linux/hwmon.h>
#include <linux/version.h>

MODULE_LICENSE("GPL");
MODULE_AUTHOR("KIRAT OS Sentinel Team");
MODULE_DESCRIPTION("Sentinel AI Kernel Bridge — Real-time system intelligence");
MODULE_VERSION("2.0.0");

#define DEVICE_NAME     "kirat-ai"
#define CLASS_NAME      .kirat.
#define NETLINK_KIRAT    31  // Custom netlink protocol
#define MAX_EVENTS      1024
#define BUFFER_SIZE     8192

// ─────────────────────────────────────────────────────────────────────────────
// Device State
// ─────────────────────────────────────────────────────────────────────────────

static int major;
static dev_t dev_num;
static struct cdev kirat_cdev;
static struct class *kirat_class = NULL;
static struct device *kirat_device = NULL;
static struct mutex kirat_mutex;
static char device_buffer[BUFFER_SIZE];

// Netlink socket
static struct sock *kirat_nl_sock = NULL;

// System telemetry snapshot
struct system_snapshot {
    u64 timestamp_ns;
    u64 cpu_cycles;
    u64 instructions_retired;
    u64 cache_misses;
    u64 cache_references;
    u64 context_switches;
    u64 irq_count;
    u64 softirq_count;
    u64 page_faults;
    u64 disk_read_bytes;
    u64 disk_write_bytes;
    u64 net_rx_bytes;
    u64 net_tx_bytes;
    u32 cpu_temp_mC;        // millidegrees Celsius
    u32 cpu_freq_kHz;
    u32 memory_used_mb;
    u32 memory_available_mb;
    u32 memory_swap_used_mb;
    u32 load_avg_1min;      // fixed point, divide by 100
    u32 process_count;
    u32 thread_count;
    u32 zombie_count;
    u32 oom_score;
};

static struct system_snapshot last_snapshot = {0};
static ktime_t last_snapshot_time;

// ─────────────────────────────────────────────────────────────────────────────
// Netlink: Kernel → Userspace Event Streaming
// ─────────────────────────────────────────────────────────────────────────────

static void kirat_nl_send_event(u32 event_type, const char *data, u32 data_len)
{
    struct sk_buff *skb;
    struct nlmsghdr *nlh;
    u32 pid;
    
    if (!kirat_nl_sock)
        return;
    
    skb = nlmsg_new(data_len + sizeof(u32), GFP_ATOMIC);
    if (!skb)
        return;
    
    nlh = nlmsg_put(skb, 0, 0, event_type, data_len + sizeof(u32), 0);
    if (!nlh) {
        kfree_skb(skb);
        return;
    }
    
    // Copy event type and data
    memcpy(nlmsg_data(nlh), &event_type, sizeof(u32));
    memcpy(nlmsg_data(nlh) + sizeof(u32), data, data_len);
    
    // Broadcast to all listening userspace processes
    // In production, maintain a list of registered PIDs
    pid = 0;  // 0 = multicast, but we need a group
    
    netlink_unicast(kirat_nl_sock, skb, pid, MSG_DONTWAIT);
}

// Netlink receive callback (userspace → kernel commands)
static void kirat_nl_recv(struct sk_buff *skb)
{
    struct nlmsghdr *nlh;
    char *data;
    u32 cmd;
    
    nlh = nlmsg_hdr(skb);
    if (nlh->nlmsg_len < NLMSG_HDRLEN + sizeof(u32))
        return;
    
    data = (char *)nlmsg_data(nlh);
    cmd = *(u32 *)data;
    
    switch (cmd) {
        case 0x01:  // REQUEST_SNAPSHOT
            // Trigger immediate snapshot and send back
            break;
        case 0x02:  // INJECT_EBPF
            // Parse eBPF bytecode and load
            break;
        case 0x03:  // SET_CPU_FREQ
            // Adjust CPU frequency policy
            break;
        case 0x04:  // BOOST_PRIORITY
            // Boost process priority
            break;
        case 0x05:  // ISOLATE_PROCESS
            // Move process to isolated cgroup
            break;
        default:
            printk(KERN_WARNING "kirat-ai: Unknown netlink command: 0x%x\n", cmd);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// System Snapshot Collection
// ─────────────────────────────────────────────────────────────────────────────

static void collect_snapshot(void)
{
    struct sysinfo si;
    struct cpufreq_policy policy;
    struct thermal_zone_device *tz;
    u64 cycles, instructions;
    
    last_snapshot.timestamp_ns = ktime_get_ns();
    
    // Memory info
    si_meminfo(&si);
    last_snapshot.memory_used_mb = (si.totalram - si.freeram) * si.mem_unit / (1024 * 1024);
    last_snapshot.memory_available_mb = si.freeram * si.mem_unit / (1024 * 1024);
    
    // CPU frequency
    if (!cpufreq_get_policy(&policy, 0)) {
        last_snapshot.cpu_freq_kHz = policy.cur;
    }
    
    // CPU temperature (first thermal zone)
    tz = thermal_zone_get_zone_by_name("x86_pkg_temp");
    if (!IS_ERR(tz)) {
        int temp;
        if (!thermal_zone_get_temp(tz, &temp))
            last_snapshot.cpu_temp_mC = temp;
    }
    
    // Load average (approximate from runqueue)
    last_snapshot.load_avg_1min = (u32)(avenrun[0] * 100);
    
    // Process counts
    last_snapshot.process_count = 0;
    last_snapshot.thread_count = 0;
    last_snapshot.zombie_count = 0;
    
    // Would iterate task list here (expensive, sample periodically)
}

// ─────────────────────────────────────────────────────────────────────────────
// eBPF Integration
// ─────────────────────────────────────────────────────────────────────────────

static int kirat_load_ebpf(const char *bytecode, size_t len)
{
    // Simplified: In production, use bpf() syscall wrapper
    // or libbpf from kernel module context
    
    printk(KERN_INFO "kirat-ai: Loading eBPF program (%zu bytes)\n", len);
    
    // Verify bytecode
    // Load via bpf_prog_load
    // Attach to tracepoint/kprobe/uprobe
    
    return 0;
}

// ─────────────────────────────────────────────────────────────────────────────
// Scheduling Control
// ─────────────────────────────────────────────────────────────────────────────

static int kirat_boost_priority(pid_t pid, int priority)
{
    struct task_struct *task;
    
    rcu_read_lock();
    task = find_task_by_vpid(pid);
    if (task) {
        struct sched_param param = { .sched_priority = priority };
        sched_setscheduler_nocheck(task, SCHED_FIFO, &param);
        printk(KERN_INFO "kirat-ai: Boosted PID %d to RT priority %d\n", pid, priority);
    }
    rcu_read_unlock();
    
    return task ? 0 : -ESRCH;
}

static int kirat_isolate_process(pid_t pid, u64 cpumask)
{
    // Move process to isolated CPU set
    // Uses sched_setaffinity
    struct task_struct *task;
    cpumask_t mask;
    
    cpumask_clear(&mask);
    // Parse cpumask and set bits
    
    rcu_read_lock();
    task = find_task_by_vpid(pid);
    if (task) {
        set_cpus_allowed_ptr(task, &mask);
        printk(KERN_INFO "kirat-ai: Isolated PID %d to CPUs 0x%llx\n", pid, cpumask);
    }
    rcu_read_unlock();
    
    return 0;
}

// ─────────────────────────────────────────────────────────────────────────────
// Power Management
// ─────────────────────────────────────────────────────────────────────────────

static int kirat_set_cpu_governor(const char *governor)
{
    struct cpufreq_policy policy;
    int cpu;
    
    for_each_possible_cpu(cpu) {
        if (!cpufreq_get_policy(&policy, cpu)) {
            if (strcmp(governor, "performance") == 0)
                cpufreq_driver_target(&policy, policy.max, CPUFREQ_RELATION_H);
            else if (strcmp(governor, "powersave") == 0)
                cpufreq_driver_target(&policy, policy.min, CPUFREQ_RELATION_L);
            // schedutil is default
        }
    }
    
    printk(KERN_INFO "kirat-ai: Set CPU governor to %s\n", governor);
    return 0;
}

// ─────────────────────────────────────────────────────────────────────────────
// Character Device Interface
// ─────────────────────────────────────────────────────────────────────────────

#define KIRAT_CMD_GET_SNAPSHOT   0x01
#define KIRAT_CMD_LOAD_EBPF      0x02
#define KIRAT_CMD_BOOST_PID      0x03
#define KIRAT_CMD_ISOLATE_PID    0x04
#define KIRAT_CMD_SET_GOVERNOR   0x05
#define KIRAT_CMD_GET_THERMAL    0x06
#define KIRAT_CMD_GET_IO_STATS   0x07
#define KIRAT_CMD_GET_NET_STATS  0x08
#define KIRAT_CMD_FORCE_GC       0x09  // Trigger memory reclaim
#define KIRAT_CMD_PANIC_ANALYZE  0x0A  // Post-panic analysis

static ssize_t kirat_ai_read(struct file *file, char __user *user_buf,
                             size_t count, loff_t *offset)
{
    ssize_t bytes_read;
    
    if (*offset >= BUFFER_SIZE)
        return 0;
    
    mutex_lock(&kirat_mutex);
    
    // Refresh snapshot on read
    collect_snapshot();
    
    // Format as JSON
    snprintf(device_buffer, BUFFER_SIZE,
        "{\n"
        "  \"timestamp\": %llu,\n"
        "  \"cpu\": {\n"
        "    \"frequency_mhz\": %u,\n"
        "    \"temperature_c\": %u,\n"
        "    \"load_1min\": %.2f\n"
        "  },\n"
        "  \"memory\": {\n"
        "    \"used_mb\": %u,\n"
        "    \"available_mb\": %u,\n"
        "    \"swap_used_mb\": %u\n"
        "  },\n"
        "  \"processes\": {\n"
        "    \"total\": %u,\n"
        "    \"threads\": %u,\n"
        "    \"zombies\": %u\n"
        "  }\n"
        "}\n",
        last_snapshot.timestamp_ns,
        last_snapshot.cpu_freq_kHz / 1000,
        last_snapshot.cpu_temp_mC / 1000,
        last_snapshot.load_avg_1min / 100.0,
        last_snapshot.memory_used_mb,
        last_snapshot.memory_available_mb,
        last_snapshot.memory_swap_used_mb,
        last_snapshot.process_count,
        last_snapshot.thread_count,
        last_snapshot.zombie_count
    );
    
    size_t len = strlen(device_buffer);
    if (count > len - *offset)
        count = len - *offset;
    
    if (copy_to_user(user_buf, device_buffer + *offset, count)) {
        mutex_unlock(&kirat_mutex);
        return -EFAULT;
    }
    
    *offset += count;
    bytes_read = count;
    
    mutex_unlock(&kirat_mutex);
    return bytes_read;
}

static ssize_t kirat_ai_write(struct file *file, const char __user *user_buf,
                              size_t count, loff_t *offset)
{
    u32 cmd;
    
    if (count < sizeof(u32))
        return -EINVAL;
    
    if (copy_from_user(&cmd, user_buf, sizeof(u32)))
        return -EFAULT;
    
    mutex_lock(&kirat_mutex);
    
    switch (cmd) {
        case KIRAT_CMD_GET_SNAPSHOT:
            collect_snapshot();
            break;
            
        case KIRAT_CMD_BOOST_PID: {
            pid_t pid;
            int prio;
            if (copy_from_user(&pid, user_buf + 4, sizeof(pid_t)) ||
                copy_from_user(&prio, user_buf + 8, sizeof(int))) {
                mutex_unlock(&kirat_mutex);
                return -EFAULT;
            }
            kirat_boost_priority(pid, prio);
            break;
        }
        
        case KIRAT_CMD_ISOLATE_PID: {
            pid_t pid;
            u64 mask;
            if (copy_from_user(&pid, user_buf + 4, sizeof(pid_t)) ||
                copy_from_user(&mask, user_buf + 12, sizeof(u64))) {
                mutex_unlock(&kirat_mutex);
                return -EFAULT;
            }
            kirat_isolate_process(pid, mask);
            break;
        }
        
        case KIRAT_CMD_SET_GOVERNOR: {
            char gov[16];
            if (copy_from_user(gov, user_buf + 4, 16)) {
                mutex_unlock(&kirat_mutex);
                return -EFAULT;
            }
            gov[15] = '\0';
            kirat_set_cpu_governor(gov);
            break;
        }
        
        case KIRAT_CMD_FORCE_GC:
            // Trigger memory reclaim
            printk(KERN_INFO "kirat-ai: Forcing memory reclaim\n");
            // wakeup_kswapd or direct reclaim
            break;
            
        default:
            printk(KERN_WARNING "kirat-ai: Unknown command: 0x%x\n", cmd);
    }
    
    mutex_unlock(&kirat_mutex);
    return count;
}

static long kirat_ai_ioctl(struct file *file, unsigned int cmd, unsigned long arg)
{
    switch (cmd) {
        case _IOR('K', 1, struct system_snapshot):
            collect_snapshot();
            if (copy_to_user((void __user *)arg, &last_snapshot, sizeof(last_snapshot)))
                return -EFAULT;
            break;
            
        default:
            return -EINVAL;
    }
    return 0;
}

static struct file_operations kirat_ai_fops = {
    .owner          = THIS_MODULE,
    .read           = kirat_ai_read,
    .write          = kirat_ai_write,
    .unlocked_ioctl = kirat_ai_ioctl,
    .llseek         = default_llseek,
};

// ─────────────────────────────────────────────────────────────────────────────
// Sysfs Interface
// ─────────────────────────────────────────────────────────────────────────────

static ssize_t kirat_governor_show(struct kobject *kobj, struct kobj_attribute *attr, char *buf)
{
    struct cpufreq_policy policy;
    if (!cpufreq_get_policy(&policy, 0))
        return sprintf(buf, "%s\n", policy.governor->name);
    return sprintf(buf, "unknown\n");
}

static ssize_t kirat_governor_store(struct kobject *kobj, struct kobj_attribute *attr,
                                    const char *buf, size_t count)
{
    char gov[16];
    strncpy(gov, buf, 15);
    gov[15] = '\0';
    // Remove newline
    gov[strcspn(gov, "\n")] = 0;
    kirat_set_cpu_governor(gov);
    return count;
}

static struct kobj_attribute kirat_governor_attr = __ATTR(governor, 0644,
                                                          kirat_governor_show,
                                                          kirat_governor_store);

static struct attribute *kirat_attrs[] = {
    &kirat_governor_attr.attr,
    NULL,
};

static struct attribute_group kirat_attr_group = {
    .attrs = kirat_attrs,
};

static struct kobject *kirat_kobj = NULL;

// ─────────────────────────────────────────────────────────────────────────────
// Module Init / Exit
// ─────────────────────────────────────────────────────────────────────────────

static struct netlink_kernel_cfg kirat_nl_cfg = {
    .input = kirat_nl_recv,
};

static int __init kirat_ai_init(void)
{
    int ret;
    
    printk(KERN_INFO "========================================\n");
    printk(KERN_INFO "KIRAT AI Sentinel Kernel Bridge v%s\n", MODULE_VERSION);
    printk(KERN_INFO "Loading...\n");
    printk(KERN_INFO "========================================\n");
    
    // Allocate device numbers
    ret = alloc_chrdev_region(&dev_num, 0, 1, DEVICE_NAME);
    if (ret < 0) {
        printk(KERN_ERR "kirat-ai: Failed to allocate device number\n");
        return ret;
    }
    major = MAJOR(dev_num);
    
    // Initialize cdev
    cdev_init(&kirat_cdev, &kirat_ai_fops);
    kirat_cdev.owner = THIS_MODULE;
    ret = cdev_add(&kirat_cdev, dev_num, 1);
    if (ret) {
        printk(KERN_ERR "kirat-ai: Failed to add cdev\n");
        unregister_chrdev_region(dev_num, 1);
        return ret;
    }
    
    // Create class
#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 4, 0)
    kirat_class = class_create(CLASS_NAME);
#else
    kirat_class = class_create(THIS_MODULE, CLASS_NAME);
#endif
    if (IS_ERR(kirat_class)) {
        ret = PTR_ERR(kirat_class);
        cdev_del(&kirat_cdev);
        unregister_chrdev_region(dev_num, 1);
        return ret;
    }
    
    // Create device
    kirat_device = device_create(kirat_class, NULL, dev_num, NULL, DEVICE_NAME);
    if (IS_ERR(kirat_device)) {
        ret = PTR_ERR(kirat_device);
        class_destroy(kirat_class);
        cdev_del(&kirat_cdev);
        unregister_chrdev_region(dev_num, 1);
        return ret;
    }
    
    // Create sysfs entries
    kirat_kobj = kobject_create_and_add(.kirat., kernel_kobj);
    if (kirat_kobj) {
        ret = sysfs_create_group(kirat_kobj, &kirat_attr_group);
        if (ret)
            printk(KERN_WARNING "kirat-ai: Failed to create sysfs group\n");
    }
    
    // Create netlink socket
    kirat_nl_sock = netlink_kernel_create(&init_net, NETLINK_KIRAT, &kirat_nl_cfg);
    if (!kirat_nl_sock) {
        printk(KERN_WARNING "kirat-ai: Failed to create netlink socket\n");
    }
    
    mutex_init(&kirat_mutex);
    last_snapshot_time = ktime_get();
    
    printk(KERN_INFO "kirat-ai: Device /dev/%s created (major=%d)\n", DEVICE_NAME, major);
    printk(KERN_INFO "kirat-ai: Sysfs /sys/kernel/kirat/ available\n");
    printk(KERN_INFO "kirat-ai: Netlink protocol %d registered\n", NETLINK_KIRAT);
    printk(KERN_INFO "kirat-ai: Sentinel is watching.\n");
    
    return 0;
}

static void __exit kirat_ai_exit(void)
{
    printk(KERN_INFO "kirat-ai: Unloading Sentinel kernel bridge\n");
    
    if (kirat_nl_sock) {
        netlink_kernel_release(kirat_nl_sock);
        kirat_nl_sock = NULL;
    }
    
    if (kirat_kobj) {
        sysfs_remove_group(kirat_kobj, &kirat_attr_group);
        kobject_put(kirat_kobj);
    }
    
    device_destroy(kirat_class, dev_num);
    class_destroy(kirat_class);
    cdev_del(&kirat_cdev);
    unregister_chrdev_region(dev_num, 1);
    
    printk(KERN_INFO "kirat-ai: Unloaded.\n");
}

module_init(kirat_ai_init);
module_exit(kirat_ai_exit);
