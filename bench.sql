-- =============================================================
-- MySQL 索引优化实验 · 造数脚本
-- 目标：在任意 MySQL 5.6+ 实例上，用约 10 秒造出 102 万行订单表
-- 用法：mysql -uroot -p < bench.sql
-- 注意：会先 DROP 已存在的 bench.orders，请勿在业务库执行
-- =============================================================

CREATE DATABASE IF NOT EXISTS bench;
USE bench;

DROP TABLE IF EXISTS orders;

-- 典型订单表：主键 + 维度列 + 度量列 + 时间列，不建任何二级索引
CREATE TABLE orders (
  id INT AUTO_INCREMENT PRIMARY KEY,
  user_id INT NOT NULL,
  status TINYINT NOT NULL,
  amount DECIMAL(10,2) NOT NULL,
  create_time DATETIME NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- -------------------------------------------------------------
-- 第一步：交叉连接一次性生成 1000 行随机数据
-- 10 x 10 x 10 = 1000 行，不需要写 1000 条 INSERT
-- -------------------------------------------------------------
INSERT INTO orders (user_id, status, amount, create_time)
SELECT
  FLOOR(RAND() * 1000),                 -- user_id: 0-999
  FLOOR(RAND() * 5),                    -- status : 0-4，基数低
  ROUND(RAND() * 1000, 2),              -- amount : 0.00-1000.00
  NOW() - INTERVAL FLOOR(RAND() * 365) DAY  -- create_time: 近一年内
FROM
  (SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5
   UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9 UNION ALL SELECT 10) a,
  (SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5
   UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9 UNION ALL SELECT 10) b,
  (SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5
   UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9 UNION ALL SELECT 10) c;

-- -------------------------------------------------------------
-- 第二步：原地翻倍到 100 万行以上
-- 1000 -> 2000 -> 4000 -> ... -> 1024000
-- 只复制已有组合，不扩展取值多样性（见 README 的「坑」一节）
-- -------------------------------------------------------------
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

DROP PROCEDURE fill_orders;

-- -------------------------------------------------------------
-- 第三步：校验
-- 预期：1024000 行；在 1 核 2G 上造数耗时约 5-6 秒
-- -------------------------------------------------------------
SELECT COUNT(*) AS total_rows FROM orders;

-- 确认表上没有任何二级索引（只有主键）
SHOW INDEX FROM orders;
