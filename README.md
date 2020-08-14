# notes
Technical notes

## Prometheus và k8s

#### Với mình lý do chính dùng prometheus là để tận dụng Service Discovery(SD) của nó.

Instance prometheus chạy trong k8s sẽ dùng Pod SD để discover các pods và node.

ref: `https://prometheus.io/docs`

Thực ra thì các instance prometheus chạy ngoài k8s vẫn discover được nhưng theo mình thì không nên làm vậy, vì nó sẽ bị phụ thuộc vào network từ prometheus -> k8s API.

#### Để prometheus có để discover được Pods :

##### Instance prometheus.
- Nếu instance đó không chạy trong k8s -> cần set thông tin về API-Server và cách để prometheus authen với k8s.
- Nếu instance đã chạy trong k8s (recommand) thì bạn không cần làm gì cả, vì nó dùng Service Account của Pods để authen với API-Server.

##### Thêm job sau vào promtheus config 
    
    - job_name: kubernetes-pods
      honor_timestamps: true
      scrape_interval: 30s
      scrape_timeout: 10s
      metrics_path: /metrics
      scheme: http
      kubernetes_sd_configs:
      - role: pod
      relabel_configs:
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
        separator: ;
        regex: "true"
        replacement: $1
        action: keep
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_path]
        separator: ;
        regex: (.+)
        target_label: __metrics_path__
        replacement: $1
        action: replace
      - source_labels: [__address__, __meta_kubernetes_pod_annotation_prometheus_io_port]
        separator: ;
        regex: ([^:]+)(?::\d+)?;(\d+)
        target_label: __address__
        replacement: $1:$2
        action: replace
      - separator: ;
        regex: __meta_kubernetes_pod_label_(.+)
        replacement: $1
        action: labelmap
      - source_labels: [__meta_kubernetes_namespace]
        separator: ;
        regex: (.*)
        target_label: kubernetes_namespace
        replacement: $1
        action: replace
      - source_labels: [__meta_kubernetes_pod_name]
        separator: ;
        regex: (.*)
        target_label: kubernetes_pod_name
        replacement: $1
        action: replace
    

#### Sau khi thêm vào thì các `Deployment` trong cluster chỉ cần set annontation cho pod spec:

`prometheus.io/scrape: "true"` -> notify prometheus cào metrics của pod.

`prometheus.io/path: "/metrics"` -> metrics path của pod, nếu pods có path khác /metrics thì mới cần set annontation này.

`prometheus.io/port: "8080"`   -> port của /metrics, có thể set nhiều port bằng dấu ',' .

```
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      workload.user.cattle.io/workloadselector: deployment-default-nginx
  strategy:
    type: RollingUpdate
  template:
    metadata:
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8080"
  ...
```

Vậy là các service được deploy lên k8s cluster sẽ được prometheus tự cào metrics về bằng job `kubernetes-pods`.

#### Flow của pod discovery cũng khá dễ hiểu, sẽ có một đọan code connect tới Kube-API server, sau đó watch các pods mới được tạo ra từ Kube-API và check annontation của Pod rồi update config cuả Prometheus.

ref: `https://github.com/prometheus/prometheus`

## VictoriaMetrics 1

### https://victoriametrics.github.io/

### Tại sao phải cần một remote storage cho prometheus ?

Trong quá trình làm việc với prometheus thì một số team cần lưu metrics trong 1 - 2 tháng hoặc lâu hơn.

### 1. Cách đầu tiên mình nghĩ là chỉ cần set retention lên 2 tháng là được.

Giả sử instance prometheus đang chạy có `875475` TSDB với retention là 5 ngày, cost 1x GB RAM. Thì việc nâng retention lên 2 tháng là gần như không thể vì sẽ cần 1 instance siêu to khổng lồ.

Chưa kể quá trình trình GC và load metrics của prometheus sẽ làm node tốn kha khá resource lúc query long range -> OOM killed.

```
/ $ ./prometheus/prometheus-2.13.0.linux-amd64/tsdb analyze prometheus/
Block ID: 01EAH2V9DMGK96ZNX6GS4T9DK7
Duration: 2h0m0s
Series: 875475
Label names: 354
Postings (unique label pairs): 38425
Postings entries (total label pairs): 11072071
```

### 2. Feredate metrics cần lưu về một instance prometheus khác.

Đây cũng chỉ là một gỉai pháp tình thế, không khá hơn #1 là bao nhiêu.

Vì bạn sẽ phải scale dọc, đắp RAM và CPU vào chỉ để đảm bảo prometheus không bị OOM nữa.

### 3. Giải pháp là remote write metrics vào một storage khác có khả năng HA và scale ngang được.

https://prometheus.io/docs/operating/integrations/#remote-endpoints-and-storage

Có rất nhều tools support làm remote storage cho Prometheus,mình chọn `VictoriaMetrics` chứ không phải những thứ fancy như Thanos, M3DB, Cortex... hoặc InfluxDB (con nhà giàu).


## Lý do chọn VictoriaMetrics:

-  Ít component, architect dễ tiếp cận, concept đơn giản.

-  Có 2 mode là cluster và single.

-  Setup nhanh trên K8s với Helm Chart: https://git.tiki.services/infras/victoriametrics

-  Prometheus cần ít RAM vì Retention và query đều ở VictoriaMetrics, Prometheus chỉ cào và gửi metrics đi.

-  Metrics retention 1 tháng hoặc có thể hơn.

-  Query performance, low cost so với các tool khác : Thanos, M3DB, Cortex...

Ref: https://github.com/VictoriaMetrics/VictoriaMetrics/wiki/CaseStudies#adidas


(...#2)