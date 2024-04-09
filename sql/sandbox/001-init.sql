CREATE TABLE exchange_rates (
  id uuid DEFAULT uuid_generate_v4() PRIMARY KEY,
  base_currency VARCHAR(3) NOT NULL,
  target_currency VARCHAR(3) NOT NULL,
  rate DECIMAL(10, 6) NOT NULL,
  exchange_date DATE NOT NULL
);

ALTER TABLE exchange_rates REPLICA IDENTITY FULL;

CREATE UNIQUE INDEX exhcange_rates_idx ON exchange_rates (base_currency, target_currency, exchange_date);

INSERT INTO exchange_rates (base_currency, target_currency, rate, exchange_date) VALUES ('HUF', 'EUR', 379.51, '2023-11-30');

CREATE TABLE collation_test (
  id serial,
  name text COLLATE "hu_HU"
);

INSERT INTO collation_test (name) VALUES ('Álmos');
INSERT INTO collation_test (name) VALUES ('alma');
INSERT INTO collation_test (name) VALUES ('akácfa');
INSERT INTO collation_test (name) VALUES ('Alma');
INSERT INTO collation_test (name) VALUES ('álmos');
INSERT INTO collation_test (name) VALUES ('arany');

SELECT * FROM collation_test ORDER BY name;
