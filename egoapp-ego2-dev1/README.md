# DATASET_APP 操作步骤

本文档用于手机端 App 与机器人端采集脚本联调。

## 1. 电脑端启动（先做）

在主机上启动 rosbridge（手机通过它收发 ROS 话题）：

```bash
ros2 launch rosbridge_server rosbridge_websocket_launch.xml
```

如果同时采机器人端数据，再启动你的机器人采集链路（相机、里程计、record 脚本）。

## 2. 手机端启动 App

1. Xcode 打开 `egoapp-ego2-dev1` 工程并运行到 iPhone。  
2. 在 App 里配置 `ROS Bridge IP`（主机 IP，端口固定 `9090`）。  
3. 点击 `Start` 开始手机侧采集和发布。

> 采集顺序：**先点手机 `Start`，再到机器人端按 `s` 开始 rosbag**。这样手机
> session 文件夹已建好，收到 `start_recording` 时能正常写入 `sync_events.csv`；
> 反过来（机器人先发 start）会因手机还没建 session 而丢掉那条 start 行。

## 3. 当前 App 会做什么

### 3.1 发布到 ROS2

点云 / 元数据：
- `/camera_person/points`
- `/camera_person/frame_meta`（`std_msgs/String`，JSON）
- `/camera_person/record_status`（`std_msgs/String`，JSON）

图像（压缩）：
- `/camera_person/color/image_raw/compressed`（`sensor_msgs/CompressedImage`，JPEG）
- `/camera_person/depth/image_raw/compressed`（`sensor_msgs/CompressedImage`）

传感器：
- `/camera_person/imu`
- `/camera_person/gps/fix`
- `/camera_person/gps/vel`

### 3.2 订阅 ROS2 同步话题

- `/dataset/sync_event`（`std_msgs/String`，JSON）

收到事件后：
- `start_recording`：自动开始采集
- `stop_recording`：自动停止采集
- `marker`：记录同步事件

### 3.3 手机本地落盘（Session）

App 会在 iPhone `Documents` 下创建：

```text
dataset_session_YYYYMMDD_HHMMSS/
  frame_meta.csv
  imu.csv
  gps.csv
  sync_events.csv
```

## 4. 联调检查

在主机终端检查手机话题是否正常：

```bash
ros2 topic echo /camera_person/frame_meta
ros2 topic echo /camera_person/record_status
ros2 topic hz /camera_person/points
```

检查同步事件是否收到：

```bash
ros2 topic echo /dataset/sync_event
```

## 5. 采集完成后

1. 从手机导出 session 文件夹（`Documents/dataset_session_*`）。  
2. 放到主机数据目录。  
3. 使用机器人端脚本做时间线对齐：

```bash
python3 scripts/merge_robot_phone_timeline.py \
  --robot-sync-csv data/dataset_bags/dataset_session_XXX/robot_sync_events.csv \
  --phone-sync-csv  <phone_session>/sync_events.csv \
  --phone-frame-csv <phone_session>/frame_meta.csv \
  --output-csv data/aligned/merged_timeline.csv
```

`robot_sync_events.csv` 由机器人端录制脚本自动写入对应 session 目录，无需手工拼。

## 6. 常见问题

1. 主机看不到手机话题  
检查手机 IP 配置是否正确、主机 `rosbridge` 是否运行、手机和主机是否同一 WLAN。

2. 手机没有响应 start/stop  
检查 `/dataset/sync_event` 格式是否为 `std_msgs/String` 且 `data` 是 JSON。

3. 点云有，元数据没有  
确认 App 已点击 `Start`，并检查主机上的 `/camera_person/frame_meta` 与 `/camera_person/record_status`。
