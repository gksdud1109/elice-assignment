-- Postgres init script. docker-entrypoint-initdb.d/ 에 마운트되어
-- 컨테이너 최초 기동시 1회 실행된다. 이미 데이터가 있으면 ON CONFLICT로
-- 중복 INSERT를 회피.

CREATE TABLE IF NOT EXISTS courses (
    id          SERIAL PRIMARY KEY,
    title       TEXT NOT NULL,
    instructor  TEXT NOT NULL
);

INSERT INTO courses (id, title, instructor) VALUES
    (1, 'Intro to SRE',         'Ben Treynor'),
    (2, 'Distributed Systems',  'Leslie Lamport'),
    (3, 'Observability 101',    'Charity Majors')
ON CONFLICT (id) DO NOTHING;

-- SERIAL sequence를 INSERT한 max id 다음으로 맞춰둔다.
SELECT setval(pg_get_serial_sequence('courses', 'id'),
              COALESCE((SELECT MAX(id) FROM courses), 1));
