# MySQL 索引优化实验：102 万行订单表的慢查询与 filesort 消除

在一个只有 **1 核 2G** 的阿里云 ECS 上，用 MySQL 5.6 构造 102 万行订单表，复现一条真实的慢查询，然后用 `EXPLAIN` 定位问题，再建联合索引把它优化掉。

不需要生产数据，不需要高配机器，全程约 10 分钟。

---

## 环境

| 项 | 值 |
|---|---|
| 机器 | 阿里云 ECS，1 vCPU / 2 GiB |
| 系统 | CentOS 7.9 x86_64 |
| 数据库 | MySQL 5.6.50（InnoDB） |
| 存储引擎 | InnoDB，默认字符集 utf8mb4 |
| 客户端 | MySQL 命令行 / 阿里云 Workbench 远程终端 |

选 1 核 2G 是刻意的：配置越差，全表扫描和 filesort 的代价越明显，优化前后的差距越能看出来。

---

## 表结构

```sql
CREATE TABLE orders (
  id INT AUTO_INCREMENT PRIMARY KEY,
  user_id INT NOT NULL,
  status TINYINT NOT NULL,
  amount DECIMAL(10,2) NOT NULL,
  create_time DATETIME NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

五个字段覆盖了典型订单表的四类列：主键、维度列（user_id / status）、度量列（amount）、时间列（create_time）。没有建任何二级索引——这是复现全表扫描的前提。

---

## 怎么造 102 万行

手工写 100 万条 `INSERT` 不现实，用「原地翻倍」：

1. 用交叉连接一次性生成 1000 行随机数据；
2. 用存储过程反复执行 `INSERT ... SELECT ... FROM orders`，每次把表里的行数复制一份，行数按 1000 → 2000 → 4000 → … 指数增长；
3. 循环到 100 万行以上停止。

```sql
DELIMITER //
CREATE PROCEDURE fill_orders()
BEGIN
  WHILE (SELECT COUNT(*) FROM orders) < 1000000 DO
    INSERT INTO orders (user_id, status, amount, create_time)
    SELECT user_id, status, amount, create_time FROM orders;
  END WHILE;
END //
DELIMITER ;
CALL fill_orders();
```

实测：`CALL fill_orders();` 返回 `512000 rows affected (5.53 sec)`，最终表里 **1,024,000 行**。

5.53 秒在一台 1 核 2G 的机器上是很正常的速度，不要以为写错了。

### 这种方法有一个坑，必须知道

翻倍只**复制已有组合**，不会**扩展取值多样性**。初始那 1000 行如果某个 `user_id` 恰好没出现，翻倍之后它永远不会出现。

我第一次用的查询条件是 `WHERE user_id = 123 AND status = 3`，结果 `COUNT(*)` 返回 **0** —— 不是索引没生效，是这个 `user_id` 从头到尾就不存在。索引照样把耗时从 0.30 秒降到 0.00 秒，但"返回 0 条"这个结果在面试里是站不住的。

所以下面这组主实验，换成了按低基数维度列过滤 + 排序的写法，保证有真实返回行、且能演示 filesort 的消除。

---

## 主实验：过滤 + 排序，消除 filesort

### 查询

```sql
SELECT * FROM orders WHERE status = 3 ORDER BY amount DESC LIMIT 20;
```

`status` 等值过滤，`amount` 倒序排序取前 20 条。真实业务里这是最典型的"按状态筛选、按金额排行"页面。

### 优化前

```
20 rows in set (0.39 sec)

+----+-----------+--------+------+---------------+------+---------+------+---------+------------------------+
| id | select_type | table | type | possible_keys | key  | key_len | ref  | rows    | Extra                  |
+----+-----------+--------+------+---------------+------+---------+------+---------+------------------------+
|  1 | SIMPLE      | orders| ALL  | NULL          | NULL | NULL    | NULL | 1021815 | Using where; Using filesort |
+----+-----------+--------+------+---------------+------+---------+------+---------+------------------------+
```

三个关键信号：

- `type = ALL` —— 全表扫描，没有任何索引可用；
- `rows = 1021815` —— 优化器估算要扫全部 100 万行；
- `Extra = Using where; Using filesort` —— 过滤完还要把命中行全部取出来、在内存里重新排序。

### 建联合索引

```sql
ALTER TABLE orders ADD INDEX idx_status_amount (status, amount);
```

`(2.41 sec)` 完成。

### 优化后

```
20 rows in set (0.01 sec)

+----+-----------+--------+------+-------------------+-------------------+---------+-------+--------+-------------+
| id | select_type | table | type | possible_keys     | key               | key_len | ref   | rows   | Extra       |
+----+-----------+--------+------+-------------------+-------------------+---------+-------+--------+-------------+
|  1 | SIMPLE      | orders| ref  | idx_status_amount | idx_status_amount | 1       | const | 441250 | Using where |
+----+-----------+--------+------+-------------------+-------------------+---------+-------+--------+-------------+
```

- `type`：`ALL` → `ref`
- `Extra`：`Using where; Using filesort` → `Using where`，**filesort 消失**
- 耗时：**0.39 sec → 0.01 sec**，约 **39 倍**

---

## 结果对比

| 指标 | 优化前 | 优化后 |
|---|---|---|
| 表行数 | 1,024,000 | 1,024,000 |
| 返回行数 | 20 | 20 |
| 耗时 | 0.39 sec | 0.01 sec |
| type | ALL | ref |
| key | NULL | idx_status_amount |
| Extra | Using where; Using filesort | Using where |
| 索引构建耗时 | — | 2.41 sec |

---

## 三个值得讲清楚的点

### 1. 索引列的顺序：等值列在前，排序列在后

写成 `(status, amount)` 而不是 `(amount, status)`，是因为 `status` 是等值条件、`amount` 是排序条件。

索引按 `(status, amount)` 建好后，同一个 `status` 值内部，`amount` 天然有序。查询时 `status = 3` 定位到索引的一段，然后顺着这一段反向读取，立刻拿到前 20 条——排序这一步根本不需要发生。

反过来 `(amount, status)` 就无法让 `status` 参与过滤，`filesort` 依然存在。

### 2. 优化后 `rows` 还是 44 万，为什么说它变快了

`rows = 441250` 是优化器对"`status = 3` 大致命中多少行"的**估算**，不是实际读取行数。

`status` 只有 5 个取值，基数极低，索引的选择性天然不好——单看 `rows`，好像没快多少。真正变快的原因是：

- 优化前：扫 102 万行 → 取命中行 → 全部排序 → 取前 20；
- 优化后：按索引定位到 `status = 3` 这一段 → 顺序读前 20 条 → 停止。

**省掉的不是扫描量，是那一次全量排序。** 这也是为什么 `LIMIT 20` 能这么快的原因：一旦结果有序，`LIMIT` 让引擎读够 20 行就停，后面 44 万行根本不会被碰到。

### 3. 0.39 秒算不算"慢查询"

在 1 核 2G 上扫 102 万行花 390 毫秒，属于全表扫描的正常水平，单看绝对值不算灾难。

但这个结论有前提：这是**1 核 2G 的机器**、**单条查询**、**没有并发**。同一段 SQL 放到千万行的订单表上，扫描量放大 10 倍就是秒级；放到并发场景里，多个查询同时做全量排序，会把内存和 CPU 一起拖垮。问题不会消失，只会被放大。

所以这条 SQL 的毛病不是"慢"，而是"写法不能扩展"。

---

## 数据说明

- 全部数据由 `RAND()` 生成，属于**自造压测数据**，不是任何真实业务数据；
- 因为没有隐私风险，所以这套脚本可以完整开源、任意重跑；
- 翻倍造数会导致行内容高度重复（同一批 `user_id` / `amount` / `create_time` 反复出现），这不影响索引与执行计划的行为，但如果要做数据分布相关的实验，需要每轮重新随机生成。

实验在阿里云 ECS 上完成，脚本执行完即可 `DROP DATABASE bench;` 清理，全过程占用磁盘约 60 MB。

---

## 文件

| 文件 | 内容 |
|---|---|
| `bench.sql` | 建库、建表、交叉连接生成 1000 行、存储过程翻倍到 102 万行 |
| `bench_test.sql` | 主实验的完整测试序列：优化前查询 → EXPLAIN → 建索引 → 优化后查询 → EXPLAIN |

执行顺序：

```bash
mysql -uroot -p < bench.sql
mysql -uroot -p bench < bench_test.sql
```
