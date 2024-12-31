-- Drop and recreate database
DROP DATABASE IF EXISTS AML;
CREATE DATABASE AML;
USE AML;

-- Create customer table
CREATE TABLE customer (
	customer_id INT AUTO_INCREMENT PRIMARY KEY,
	c_surname VARCHAR(50) NOT NULL,
	c_name VARCHAR(50) NOT NULL,
	c_middle_name VARCHAR(50),
	c_date_of_birth DATE
);

-- Create countries table
CREATE TABLE countries(
	country_id VARCHAR(5) NOT NULL PRIMARY KEY,
    country_name VARCHAR(100),
	KRYT_1 FLOAT,
	KRYT_2 FLOAT,
	KRYT_3 FLOAT
);

-- Create address table with foreign key to countries
CREATE TABLE address(
	address_id INT AUTO_INCREMENT PRIMARY KEY,
    a_country_id VARCHAR(5) NOT NULL,
	a_town VARCHAR(100) NOT NULL,
	a_street VARCHAR(100) NOT NULL,
	a_street_number VARCHAR(20) NOT NULL,
	a_zip_code VARCHAR(20) NOT NULL,
    FOREIGN KEY (a_country_id) REFERENCES countries(country_id)
);

-- Create customer_status table
CREATE TABLE customer_status(
	customer_stat_id INT AUTO_INCREMENT PRIMARY KEY,
	current_risk_level FLOAT DEFAULT 1,
	previous_risk_level FLOAT DEFAULT 1,
	change_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
	risk_points INT DEFAULT 0
);

-- Create account_details table
CREATE TABLE account_details (
    account_id INT AUTO_INCREMENT PRIMARY KEY,
    account_number VARCHAR(30) NOT NULL UNIQUE,
    balance DECIMAL(10,2) DEFAULT 0,
    currency VARCHAR(5) DEFAULT 'PLN',
    opening_date DATETIME DEFAULT CURRENT_TIMESTAMP,
    closing_date DATETIME DEFAULT NULL
);

-- Create customer_info table
CREATE TABLE customer_info (
    customer_info_id INT AUTO_INCREMENT PRIMARY KEY,
    customer_id INT NOT NULL,
    address_id INT NOT NULL,
    status_id INT NOT NULL,
    account_id INT NOT NULL,
    FOREIGN KEY (customer_id) REFERENCES customer(customer_id),
    FOREIGN KEY (address_id) REFERENCES address(address_id),
    FOREIGN KEY (status_id) REFERENCES customer_status(customer_stat_id),
    FOREIGN KEY (account_id) REFERENCES account_details(account_id),
    INDEX (account_id, customer_id)
);

-- Create transactions table
CREATE TABLE transactions (
    transaction_id INT AUTO_INCREMENT PRIMARY KEY,
    payer_id INT NOT NULL,
    sender_account_id INT NOT NULL,
    beneficiary_id INT,
    beneficiary_account_id INT,
    amount DECIMAL(10, 2) NOT NULL,
    currency VARCHAR(3) DEFAULT 'PLN',
    transaction_date DATETIME DEFAULT CURRENT_TIMESTAMP,
    transaction_type ENUM('transfer', 'deposit', 'withdrawal', 'fee') NOT NULL,
    description VARCHAR(255),
    FOREIGN KEY (payer_id, sender_account_id) REFERENCES customer_info(account_id, customer_id),
    FOREIGN KEY (beneficiary_id, beneficiary_account_id) REFERENCES customer_info(account_id, customer_id)
);

-- Create suspicious_transaction_log table
CREATE TABLE suspicious_transaction_log (
    log_id INT AUTO_INCREMENT PRIMARY KEY,
    log_transaction_id INT NOT NULL,
    transaction_risk_points FLOAT,
    FOREIGN KEY (log_transaction_id) REFERENCES transactions(transaction_id)
);


CREATE TABLE currency_rates (
    currency_code VARCHAR(3) PRIMARY KEY,
    exchange_rate DECIMAL(10, 6) NOT NULL -- Kurs względem waluty bazowej, np. PLN
);





DELIMITER $$

CREATE PROCEDURE handle_transaction_logic (
    IN in_transaction_id INT
)
BEGIN
    DECLARE in_amount DECIMAL(15, 2);
    DECLARE in_transaction_type ENUM('transfer', 'deposit', 'withdrawal', 'fee');
    DECLARE in_beneficiary_id INT;
    DECLARE in_sender_id INT;
    DECLARE in_risk_points INT DEFAULT 0;
    DECLARE in_beneficiary_risk_points INT DEFAULT 0;
    DECLARE sender_risk_points INT DEFAULT 0;
    DECLARE sender_risk_level INT DEFAULT 0;
    DECLARE beneficiary_country_id VARCHAR(5);
    DECLARE risk_level INT;

    DECLARE current_level INT;
    DECLARE current_points INT;
    DECLARE required_points INT;

    -- Pobranie danych z transakcji
    SELECT amount, transaction_type, payer_id, beneficiary_id
    INTO in_amount, in_transaction_type, in_sender_id, in_beneficiary_id
    FROM transactions
    WHERE transaction_id = in_transaction_id;

    -- Logika punktów ryzyka dla depozytu
    IF in_transaction_type = 'deposit' THEN
        IF in_amount > 100000 THEN
            SET in_risk_points = in_risk_points + 10; -- Duża wpłata
        ELSEIF in_amount > 70000 THEN
            SET in_risk_points = in_risk_points + 5; -- Średnia wpłata
        ELSEIF in_amount > 30000 THEN
            SET in_risk_points = in_risk_points + 2; -- Mała wpłata
        END IF;
    END IF;

    -- Logika punktów ryzyka dla beneficjenta w kraju wysokiego ryzyka
    IF in_beneficiary_id IS NOT NULL THEN
        SELECT a.a_country_id INTO beneficiary_country_id
        FROM customer_info ci
        JOIN address a ON ci.address_id = a.address_id
        WHERE ci.customer_id = in_beneficiary_id;

        SELECT co.c_risk_level INTO risk_level
        FROM countries co
        WHERE co.country_id = beneficiary_country_id;

        IF risk_level >= 3 THEN
            IF risk_level = 3 THEN
                SET in_risk_points = in_risk_points + 5;
            ELSEIF risk_level = 4 THEN
                SET in_risk_points = in_risk_points + 10;
            ELSEIF risk_level = 5 THEN
                SET in_risk_points = in_risk_points + 15;
            END IF;
        END IF;
    END IF;

    -- Logika ryzyka dla odbiorcy, jeśli nadawca ma wysoki poziom ryzyka
    IF in_beneficiary_id IS NOT NULL THEN
        -- Pobranie ryzyka nadawcy
        SELECT risk_points, current_risk_level
        INTO sender_risk_points, sender_risk_level
        FROM customer_status
        WHERE customer_stat_id = (
            SELECT status_id
            FROM customer_info
            WHERE customer_id = in_sender_id
        );

        -- Dodanie punktów beneficjentowi w zależności od ryzyka nadawcy
        IF sender_risk_level >= 4 THEN
            SET in_beneficiary_risk_points = in_beneficiary_risk_points + 10; -- Duży poziom ryzyka
        ELSEIF sender_risk_level = 3 THEN
            SET in_beneficiary_risk_points = in_beneficiary_risk_points + 5; -- Średni poziom ryzyka
        ELSEIF sender_risk_level = 2 THEN
            SET in_beneficiary_risk_points = in_beneficiary_risk_points + 2; -- Niski poziom ryzyka
        END IF;

        -- Pobranie aktualnych punktów i poziomu beneficjenta
        SELECT current_risk_level, risk_points INTO current_level, current_points
        FROM customer_status
        WHERE customer_stat_id = (
            SELECT status_id
            FROM customer_info
            WHERE customer_id = in_beneficiary_id
        );

        -- Dodaj nowe punkty do istniejących dla beneficjenta
        SET current_points = current_points + in_beneficiary_risk_points;

        -- Ustal wymagany próg w zależności od aktualnego poziomu beneficjenta
        IF current_level = 1 THEN
            SET required_points = 30;
        ELSEIF current_level = 2 THEN
            SET required_points = 50;
        ELSEIF current_level = 3 THEN
            SET required_points = 70;
        ELSEIF current_level = 4 THEN
            SET required_points = 100;
        ELSE
            SET required_points = 999999; -- Max poziom
        END IF;

        -- Sprawdź czy beneficjent przekroczył próg i można awansować
        IF current_points >= required_points AND current_level < 5 THEN
            SET current_level = current_level + 1;
            SET current_points = 0; -- Reset punktów po awansie
        END IF;

        -- Aktualizacja statusu beneficjenta
        UPDATE customer_status
        SET risk_points = current_points,
            current_risk_level = current_level
        WHERE customer_stat_id = (
            SELECT status_id
            FROM customer_info
            WHERE customer_id = in_beneficiary_id
        );
    END IF;

    -- Wstawienie do loga podejrzanych transakcji, jeśli są punkty
    IF in_risk_points > 0 THEN
        INSERT INTO suspicious_transaction_log (log_transaction_id, transaction_risk_points)
        VALUES (in_transaction_id, in_risk_points);
    END IF;

    -- Pobranie aktualnych punktów i poziomu nadawcy
    SELECT current_risk_level, risk_points INTO current_level, current_points
    FROM customer_status
    WHERE customer_stat_id = (
        SELECT status_id
        FROM customer_info
        WHERE customer_id = in_sender_id
    );

    -- Dodaj nowe punkty do istniejących dla nadawcy
    SET current_points = current_points + in_risk_points;

    -- Ustal wymagany próg w zależności od aktualnego poziomu nadawcy
    IF current_level = 1 THEN
        SET required_points = 30;
    ELSEIF current_level = 2 THEN
        SET required_points = 50;
    ELSEIF current_level = 3 THEN
        SET required_points = 70;
    ELSEIF current_level = 4 THEN
        SET required_points = 100;
    ELSE
        SET required_points = 999999; -- Max poziom
    END IF;

    -- Sprawdź czy nadawca przekroczył próg i można awansować
    IF current_points >= required_points AND current_level < 5 THEN
        SET current_level = current_level + 1;
        SET current_points = 0; -- Reset punktów po awansie
    END IF;

    -- Aktualizacja statusu nadawcy
    UPDATE customer_status
    SET risk_points = current_points,
        current_risk_level = current_level
    WHERE customer_stat_id = (
        SELECT status_id
        FROM customer_info
        WHERE customer_id = in_sender_id
    );
END$$

DELIMITER ;



-- Trigger: After inserting a transaction
DELIMITER $$

DROP TRIGGER IF EXISTS after_transaction_insert$$

CREATE TRIGGER after_transaction_insert
AFTER INSERT ON transactions
FOR EACH ROW
BEGIN
    CALL handle_transaction_logic(NEW.transaction_id);
END$$

DELIMITER ;

-- Trigger: After inserting into suspicious_transaction_log
DELIMITER $$


DROP TRIGGER IF EXISTS after_suspicious_log_insert$$

CREATE TRIGGER after_suspicious_log_insert
AFTER INSERT ON suspicious_transaction_log
FOR EACH ROW
BEGIN
    -- Logowanie wykonania triggera
    INSERT INTO trigger_logs (trigger_name, details)
    VALUES ('after_suspicious_log_insert', CONCAT('Log ID: ', NEW.log_id));
END$$

DELIMITER ;




DELIMITER $$
DROP TRIGGER IF EXISTS before_transaction_insert$$

CREATE TRIGGER before_transaction_insert

BEFORE INSERT ON transactions
FOR EACH ROW
BEGIN
    DECLARE sender_balance DECIMAL(10,2);
    DECLARE sender_currency_rate DECIMAL(10,6);
    DECLARE transaction_currency_rate DECIMAL(10,6);
    DECLARE beneficiary_currency_rate DECIMAL(10,6);
    DECLARE converted_amount DECIMAL(10,2);

    -- Pobranie kursu waluty transakcji względem PLN
    SELECT exchange_rate INTO transaction_currency_rate
    FROM currency_rates
    WHERE currency_code = NEW.currency;

    -- Pobranie kursu waluty beneficjenta względem PLN
    IF NEW.beneficiary_account_id IS NOT NULL THEN
        SELECT exchange_rate INTO beneficiary_currency_rate
        FROM currency_rates
        WHERE currency_code = (
            SELECT currency
            FROM account_details
            WHERE account_id = NEW.beneficiary_account_id
        );
    END IF;

    -- Sprawdzenie salda nadawcy (dla wypłaty i przelewu)
    IF NEW.transaction_type IN ('withdrawal', 'transfer') THEN
        SELECT balance INTO sender_balance
        FROM account_details
        WHERE account_id = NEW.sender_account_id
        FOR UPDATE;

        IF sender_balance < NEW.amount THEN
            SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Niewystarczające środki na koncie nadawcy.';
        END IF;
    END IF;

    -- Obsługa transakcji
    IF NEW.transaction_type = 'withdrawal' THEN
        UPDATE account_details
        SET balance = balance - NEW.amount
        WHERE account_id = NEW.sender_account_id;

    ELSEIF NEW.transaction_type = 'transfer' THEN
        -- Przeliczenie kwoty na walutę beneficjenta
        IF NEW.beneficiary_account_id IS NOT NULL THEN
            SET converted_amount = NEW.amount * transaction_currency_rate / beneficiary_currency_rate;

            -- Aktualizacja salda nadawcy
            UPDATE account_details
            SET balance = balance - NEW.amount
            WHERE account_id = NEW.sender_account_id;

            -- Aktualizacja salda beneficjenta
            UPDATE account_details
            SET balance = balance + converted_amount
            WHERE account_id = NEW.beneficiary_account_id;
        END IF;

    ELSEIF NEW.transaction_type = 'deposit' THEN
        -- Aktualizacja salda beneficjenta dla wpłaty
        IF NEW.beneficiary_account_id IS NOT NULL THEN
            SET converted_amount = NEW.amount * transaction_currency_rate / beneficiary_currency_rate;

            UPDATE account_details
            SET balance = balance + converted_amount
            WHERE account_id = NEW.beneficiary_account_id;
        END IF;
    END IF;
END$$

DELIMITER ;


CREATE TABLE trigger_logs (
    log_id INT AUTO_INCREMENT PRIMARY KEY,
    trigger_name VARCHAR(50),
    event_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    details TEXT
);


INSERT INTO currency_rates (currency_code, exchange_rate) VALUES
('PLN', 1.000000),
('EUR', 4.300000),
('USD', 4.150000),
('GEL', 1.500000),
('COP', 0.001000),
('GHS', 0.280000), -- 1 GHS = 0.35 PLN
('AFN', 0.060000),
('RUB', 0.004000);


INSERT INTO countries (country_id,country_name, KRYT_1, KRYT_2, KRYT_3) VALUES
('AFG', 'Afghanistan', 4.0, 5.0, 3.294),
('COL', 'Colombia', 3.0, 2.857142857, 2.887),
('FIN', 'Finland', 0.65, 0.0, 1.474),
('GEO', 'Georgia', 2.35, 3.571428571, 2.195),
('DEU', 'Germany', 1.1, 0.714285714, 1.542),
('GHA', 'Ghana', 2.85, 5.0, 1.938),
('LVA', 'Latvia', 2.0, 2.142857143, 1.661),
('IRL', 'Ireland', 1.15, 1.428571429, 1.303),
('GRC', 'Greece', 2.55, 3.571428571, 1.793),
('POL', 'Poland', 2.3, 2.142857143, 1.678),
('RUS', 'Russia', 3.7, 5.0, 3.249),
('PRT', 'Portugal', 1.95, 2.857142857, 1.372);
INSERT INTO address (a_country_id, a_town, a_street, a_street_number, a_zip_code) VALUES
-- Polska (POL)
('POL', 'Warsaw', 'Marszałkowska', '10A', '00-017'),
('POL', 'Krakow', 'Floriańska', '22', '31-021'),
('POL', 'Gdansk', 'Długa', '5B', '80-831'),

-- Niemcy (DEU)
('DEU', 'Berlin', 'Unter den Linden', '45', '10117'),
('DEU', 'Munich', 'Marienplatz', '8', '80331'),
('DEU', 'Hamburg', 'Reeperbahn', '18A', '20359'),

-- Finlandia (FIN)
('FIN', 'Helsinki', 'Mannerheimintie', '12', '00100'),
('FIN', 'Espoo', 'Otaniementie', '5C', '02150'),
('FIN', 'Tampere', 'Hämeenkatu', '34', '33200'),

-- Afganistan (AFG)
('AFG', 'Kabul', 'Shahre Naw', '77', '1001'),
('AFG', 'Herat', 'Shahr-e Naw', '23A', '3001'),
('AFG', 'Mazar-i-Sharif', 'Balkh Street', '17', '4001'),

-- Kolumbia (COL)
('COL', 'Bogota', 'Calle 26', '90-55', '110931'),
('COL', 'Medellin', 'Carrera 70', '45B', '050021'),
('COL', 'Cali', 'Avenida 6N', '13A', '760001'),

-- Gruzja (GEO)
('GEO', 'Tbilisi', 'Rustaveli Avenue', '35', '0108'),
('GEO', 'Batumi', 'Gamsakhurdia Street', '12', '6000'),
('GEO', 'Kutaisi', 'Paliashvili Street', '25', '4600'),

-- Ghana (GHA)
('GHA', 'Accra', 'Independence Avenue', '34', 'GA-002-4221'),
('GHA', 'Kumasi', 'Asafo Market Street', '15', 'AK-040-2210'),
('GHA', 'Tamale', 'Nyohini Street', '5', 'TL-0002'),

-- Grecja (GRC)
('GRC', 'Athens', 'Ermou Street', '45', '10563'),
('GRC', 'Thessaloniki', 'Aristotelous Square', '23', '54623'),
('GRC', 'Patras', 'Agiou Andreou', '67', '26221'),

-- Irlandia (IRL)
('IRL', 'Dublin', 'O\'Connell Street', '55', 'D01F6F8'),
('IRL', 'Cork', 'St Patrick Street', '22', 'T12H765'),
('IRL', 'Galway', 'Shop Street', '7', 'H91XV56'),

-- Łotwa (LVA)
('LVA', 'Riga', 'Brivibas Street', '15', 'LV-1010'),
('LVA', 'Daugavpils', 'Rigas Street', '7B', 'LV-5401'),
('LVA', 'Liepaja', 'Kungu Street', '11', 'LV-3401'),

-- Rosja (RUS)
('RUS', 'Moscow', 'Arbat Street', '8A', '119019'),
('RUS', 'Saint Petersburg', 'Nevsky Prospekt', '25', '191186'),
('RUS', 'Kazan', 'Baumana Street', '30', '420111'),

-- Portugalia (PRT)
('PRT', 'Lisbon', 'Rua Augusta', '130', '1100-048'),
('PRT', 'Porto', 'Avenida dos Aliados', '23', '4000-064'),
('PRT', 'Coimbra', 'Rua da Sofia', '67', '3000-389');



INSERT INTO customer (c_surname, c_name, c_middle_name, c_date_of_birth) VALUES
-- Polska
('Kowalski', 'Jan', 'Adam', '1985-02-15'),
('Nowak', 'Anna', 'Maria', '1990-06-12'),
('Wiśniewski', 'Piotr', NULL, '1978-09-23'),
('Wiśniewska', 'Anna','Maria', '2005-09-23'),

-- Niemcy
('Müller', 'Hans', 'Johann', '1980-01-11'),
('Müller', 'Hannah', 'NULL', '1987-04-10'),
('Schmidt', 'Julia', NULL, '1995-03-25'),
('Schneider', 'Klaus', 'Friedrich', '1987-07-30'),

-- Finlandia
('Virtanen', 'Matti', 'Juhani', '1992-12-14'),
('Korhonen', 'Laura', 'Elina', '1988-04-05'),
('Nieminen', 'Kari', NULL, '1975-08-17'),

-- Afganistan
('Ahmadi', 'Mohammad', 'Ali', '1983-05-21'),
('Karimi', 'Fatima', NULL, '1991-02-03'),
('Rahimi', 'Abdullah', 'Omar', '1979-11-09'),

-- Kolumbia
('Gonzalez', 'Carlos', 'Luis', '1984-07-10'),
('Rodriguez', 'Maria', 'Isabel', '1993-06-18'),
('Lopez', 'Juan', 'Pablo', '1986-01-02'),

-- Gruzja
('Beridze', 'Nino', 'Tamar', '1990-09-29'),
('Gelashvili', 'Giorgi', NULL, '1995-10-15'),
('Khutsishvili', 'Ana', 'Natia', '1977-03-11'),
('Khutsishvili', 'Anika', 'Ana', '2003-03-11'),

-- Ghana
('Mensah', 'Kwame', 'John', '1982-04-22'),
('Boateng', 'Abena', NULL, '1994-01-18'),
('Owusu', 'Kofi', 'Michael', '1980-12-30'),


-- Grecja
('Papadopoulos', 'Nikos', 'Georgios', '1979-06-13'),
('Ioannou', 'Elena', NULL, '1986-07-19'),
('Kostopoulos', 'Dimitrios', 'Alexandros', '1992-11-25'),

-- Irlandia
('O\'Connor', 'Liam', 'Patrick', '1983-03-15'),
('Murphy', 'Aoife', NULL, '1995-09-20'),
('Kelly', 'Sean', 'Michael', '1988-12-01'),

-- Łotwa
('Berzins', 'Janis', 'Peteris', '1990-01-08'),
('Ozols', 'Liga', NULL, '1987-02-28'),
('Kalnins', 'Arturs', 'Edgars', '1976-06-17'),

-- Rosja
('Ivanov', 'Ivan', 'Sergeevich', '1984-02-13'),
('Petrova', 'Ekaterina', NULL, '1993-04-27'),
('Smirnov', 'Alexei', 'Dmitrievich', '1981-05-30'),

-- Portugalia
('Silva', 'João', 'Miguel', '1992-07-12'),
('Fernandes', 'Sofia', NULL, '1989-11-09'),
('Costa', 'Pedro', 'André', '1985-10-05');




INSERT INTO customer_status (current_risk_level, previous_risk_level, change_date, risk_points) VALUES
-- Polska
(2, 1, '2018-06-01 12:15:00', 12),
(1, 1, '2019-05-25 09:30:00', 5),
(3, 2, '1999-06-10 14:45:00', 22),
(2, 1, '2021-04-15 11:20:00', 15),

-- Niemcy
(2, 2, '2019-05-20 08:50:00', 10),
(1, 1, '2020-05-28 10:10:00', 5),
(3, 2, '2021-06-05 16:00:00', 25),
(1, 1, '2022-04-01 07:45:00', 0),

-- Finlandia
(2, 1, '2020-03-20 13:00:00', 12),
(2, 2, '2021-06-12 15:10:00', 18),
(1, 1, '2019-05-01 10:30:00', 5),

-- Afganistan
(3, 2, '2019-06-08 14:40:00', 30),
(2, 2, '2020-05-15 12:20:00', 20),
(2, 1, '2023-04-30 08:10:00', 15),

-- Kolumbia
(4, 3, '2021-06-02 09:45:00', 40),
(2, 2, '2022-05-22 11:50:00', 18),
(3, 2, '2024-06-11 13:30:00', 25),

-- Gruzja
(1, 1, '2018-04-25 07:30:00', 5),
(2, 1, '2019-05-18 08:20:00', 10),
(3, 2, '2022-06-07 15:50:00', 22),
(2, 1, '2023-05-02 11:40:00', 15),

-- Ghana
(3, 2, '2021-05-29 10:00:00', 25),
(2, 2, '2020-04-18 09:30:00', 18),
(1, 1, '2019-03-30 08:45:00', 8),

-- Grecja
(1, 1, '2022-06-01 10:15:00', 5),
(2, 1, '2019-05-10 11:25:00', 12),
(3, 2, '2020-06-04 12:40:00', 20),

-- Irlandia
(2, 1, '2018-04-15 14:15:00', 12),
(1, 1, '2021-05-05 13:50:00', 5),
(2, 2, '2023-06-06 08:30:00', 18),

-- Łotwa
(1, 1, '2020-04-10 09:20:00', 5),
(2, 1, '2021-05-20 10:40:00', 15),
(3, 2, '2023-06-08 11:10:00', 22),

-- Rosja
(2, 2, '2021-05-15 13:45:00', 18),
(3, 2, '2022-06-01 15:25:00', 30),
(1, 1, '2018-03-28 07:10:00', 5),

-- Portugalia
(2, 1, '2019-05-12 14:35:00', 12),
(1, 1, '2020-04-22 08:50:00', 5),
(3, 2, '2024-06-03 09:30:00', 25);


-- 

INSERT INTO account_details(account_number, balance, currency, opening_date) VALUES
-- Polska

('PL9876543210987654', 75060.50, 'PLN', '2008-06-12 11:00:00'), -- Anna Nowak
('PL1122334455667788', 9500.00, 'PLN', '1996-09-23 10:30:00'), -- Piotr Wiśniewski
('PL9988776655443322', 3000.00, 'PLN', '2023-09-23 12:00:00'), -- Anna Wiśniewska

-- Niemcy
('DE1234567890123456', 80000.75, 'EUR', '1998-01-11 08:45:00'), -- Hans Müller
('DE9876543210987654', 4200.25, 'EUR', '2005-04-10 09:15:00'), -- Hannah Müller
('DE1122334455667788', 5000.50, 'EUR', '2013-03-25 10:00:00'), -- Julia Schmidt
('DE9988776655443322', 7200.00, 'EUR', '2009-07-30 11:00:00'), -- Klaus Schneider

-- Finlandia
('FI1234567890123456', 12000.00, 'EUR', '2010-12-14 14:30:00'), -- Matti Virtanen
('FI9876543210987654', 60000.00, 'EUR', '2006-04-05 12:45:00'), -- Laura Korhonen
('FI1122334455667788', 4000.25, 'EUR', '1993-08-17 10:30:00'), -- Kari Nieminen

-- Afganistan
('AF1234567890123456', 3500.00, 'AFN', '2001-05-21 13:00:00'), -- Mohammad Ahmadi
('AF9876543210987654', 2000.75, 'AFN', '2009-02-03 14:15:00'), -- Fatima Karimi
('AF1122334455667788', 1500.50, 'AFN', '1997-11-09 15:30:00'), -- Abdullah Rahimi

-- Kolumbia
('CO1234567890123456', 450000.00, 'COP', '2002-07-10 09:45:00'), -- Carlos Gonzalez
('CO9876543210987654', 3000.00, 'COP', '2011-06-18 11:30:00'), -- Maria Rodriguez
('CO1122334455667788', 5000.25, 'COP', '2004-01-02 12:15:00'), -- Juan Lopez

-- Gruzja
('GE1234567890123456', 3800.00, 'GEL', '2008-09-29 10:15:00'), -- Nino Beridze
('GE9876543210987654', 2200.50, 'GEL', '2013-10-15 09:30:00'), -- Giorgi Gelashvili
('GE1122334455667788', 3100.75, 'GEL', '1999-03-11 08:45:00'), -- Ana Khutsishvili

-- Ghana
('GH1234567890123456', 3000.25, 'GHS', '2000-04-22 11:45:00'), -- Kwame Mensah
('GH9876543210987654', 4000.00, 'GHS', '2012-01-18 12:45:00'), -- Abena Boateng
('GH1122334455667788', 2500.50, 'GHS', '1999-12-30 10:00:00'), -- Kofi Owusu

-- Grecja
('GR1234567890123456', 7000.00, 'EUR', '1997-06-13 09:00:00'), -- Nikos Papadopoulos
('GR9876543210987654', 4700.50, 'EUR', '2004-07-19 10:15:00'), -- Elena Ioannou
('GR1122334455667788', 15000.75, 'EUR', '2010-11-25 11:30:00'), -- Dimitrios Kostopoulos

-- Irlandia
('IE1234567890123456', 6000.00, 'EUR', '2001-03-15 12:45:00'), -- Liam O'Connor
('IE9876543210987654', 3500.50, 'EUR', '2013-09-20 09:15:00'), -- Aoife Murphy
('IE1122334455667788', 7000.25, 'EUR', '2006-12-01 10:30:00'), -- Sean Kelly

-- Łotwa
('LV1234567890123456', 4200.00, 'EUR', '2008-01-08 10:00:00'), -- Janis Berzins
('LV9876543210987654', 3100.75, 'EUR', '2009-02-28 09:45:00'), -- Liga Ozols
('LV1122334455667788', 2500.50, 'EUR', '1998-06-17 12:15:00'), -- Arturs Kalnins

-- Rosja
('RU1234567890123456', 8000.00, 'RUB', '2002-02-13 09:30:00'), -- Ivan Ivanov
('RU9876543210987654', 4500.25, 'RUB', '2011-04-27 10:00:00'), -- Ekaterina Petrova
('RU1122334455667788', 7500.50, 'RUB', '1999-05-30 11:45:00'), -- Alexei Smirnov

-- Portugalia
('PT1234567890123456', 9500.00, 'EUR', '2010-07-12 09:00:00'), -- João Silva
('PT9876543210987654', 6700.50, 'EUR', '2008-11-09 10:15:00'), -- Sofia Fernandes
('PT1122334455667788', 5000.25, 'EUR', '2003-10-05 11:30:00'); -- Pedro Costa


SELECT * FROM account_details;

INSERT INTO customer_info (customer_id, address_id, status_id, account_id) VALUES
-- Polska
(1, 1, 1, 1), -- 
(2, 2, 2, 2), 
(3, 3, 3, 3), 
(4, 4, 4, 4), 

-- Niemcy
(5, 5, 5, 5), 
(6, 6, 6, 6), 
(7, 7, 7, 7), 
(8, 8, 8, 8), 

-- Finlandia
(9, 9, 9, 9), 
(10, 10, 10, 10), 
(11, 11, 11, 11), 
(12, 12, 12, 12), 

-- Afganistan
(13, 13, 13, 13), 
(14, 14, 14, 14), 
(15, 15, 15, 15), 
(16, 16, 16, 16), 

-- Kolumbia
(17, 17, 17, 17),
(18, 18, 18, 18), 
(19, 19, 19, 19), 
(20, 20, 20, 20), 

-- Gruzja
(21, 21, 21, 21), 
(22, 22, 22, 22), 
(23, 23, 23, 23), 
(24, 24, 24, 24), 

-- Ghana
(25, 25, 25, 25), 
(26, 26, 26, 26), 
(27, 27, 27, 27), 
(28, 28, 28, 28), 

-- Grecja
(29, 29, 29, 29), 
(30, 30, 30, 30), 
(31, 31, 31, 31), 
(32, 32, 32, 32), 

-- Irlandia
(33, 33, 33, 33), 
(34, 34, 34, 34), 
(35, 35, 35, 35), 
(36, 36, 36, 36), 

-- Łotwa
(37, 36, 37, 37); 




