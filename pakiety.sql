CREATE OR REPLACE TYPE t_num_list AS TABLE OF NUMBER;
/
CREATE OR REPLACE TYPE t_num_tab AS TABLE OF NUMBER;
/
CREATE OR REPLACE TYPE t_przedzial_cenowy IS VARRAY(10) OF NUMBER;
/
CREATE OR REPLACE TYPE t_wolna_sala_obj AS OBJECT (
    data_dnia    DATE,
    godzina      VARCHAR2(5),
    numer_sali   INTEGER,
    ilosc_miejsc INTEGER
);
/
CREATE OR REPLACE TYPE t_wolna_sala_tab AS TABLE OF t_wolna_sala_obj;
/

CREATE INDEX ix_przed_slot ON PRZEDSTAWIENIE(DATA_PRZEDSTAWIENIA, GODZINA_PRZEDSTAWIENIA);
CREATE INDEX ix_przed_sala ON PRZEDSTAWIENIE(SALA_ID_SALI, DATA_PRZEDSTAWIENIA, GODZINA_PRZEDSTAWIENIA);
CREATE INDEX ix_obsada_prac ON PRZEDSTAWIENIE_PRACOWNIK(PRACOWNICY_TEATRU_ID_PRACOWNIKA);

CREATE OR REPLACE PACKAGE pkg_obsada AS

  c_ok             CONSTANT NUMBER := 0;
  c_error_user     CONSTANT NUMBER := 1;
  c_error_system   CONSTANT NUMBER := 2; 

  TYPE t_lista_rol IS TABLE OF VARCHAR2(80) INDEX BY PLS_INTEGER;

  PROCEDURE przypisz_pracownika(
    p_przed_id      IN NUMBER,  
    p_rola_id       IN NUMBER, 
    p_pracownik_id  IN NUMBER, 
    p_status        OUT NUMBER, 
    p_msg           OUT VARCHAR2 
  );

END pkg_obsada;
/

CREATE OR REPLACE PACKAGE pkg_grafik AS

  c_sukces         CONSTANT NUMBER := 0;
  c_blad_danych    CONSTANT NUMBER := 1; 
  c_blad_systemu   CONSTANT NUMBER := 2; 

  PROCEDURE przypisz_sale(
    p_przed_id      IN NUMBER,
    p_sala_docel    IN NUMBER,
    p_data          IN DATE,
    p_godz          IN DATE,
    p_status        OUT NUMBER,
    p_msg           OUT VARCHAR2
  );

  PROCEDURE optymalizuj_grafik(
    p_data          IN DATE,
    p_godz          IN DATE DEFAULT NULL,
    p_status        OUT NUMBER,
    p_msg           OUT VARCHAR2
  );

END pkg_grafik;
/

CREATE OR REPLACE PACKAGE pkg_bilety AS

  c_sukces         CONSTANT NUMBER := 0;
  c_blad_danych    CONSTANT NUMBER := 1; 
  c_blad_systemu   CONSTANT NUMBER := 2; 

  TYPE t_mapa_znizek IS TABLE OF NUMBER INDEX BY VARCHAR2(50);

  PROCEDURE sprzedaj_bilet(
    p_bilet_id      IN NUMBER,
    p_przed_id      IN NUMBER,
    p_klient_id     IN NUMBER,
    p_znizka_nazwa  IN VARCHAR2,
    p_typ_miejsca   IN NUMBER,   
    p_platnosc      IN VARCHAR2,
    p_koszt_out     OUT NUMBER,
    p_status        OUT NUMBER,
    p_msg           OUT VARCHAR2
  );

  FUNCTION sprawdz_dostepnosc(p_przed_id IN NUMBER) RETURN NUMBER;

END pkg_bilety;
/

CREATE OR REPLACE PACKAGE pkg_zastepstwa AS

  c_sukces         CONSTANT NUMBER := 0;
  c_blad_logiczny  CONSTANT NUMBER := 1; 
  c_blad_danych    CONSTANT NUMBER := 2; 


  FUNCTION dostepni_pracownicy_pipe(
    p_rola_id IN NUMBER, 
    p_d       IN DATE, 
    p_g       IN DATE
  ) RETURN t_num_list PIPELINED;

  PROCEDURE zglos_chorobe(
    p_przed_id      IN NUMBER,    
    p_rola_id       IN NUMBER,    
    p_chory_prac_id IN NUMBER,    
    p_status        OUT NUMBER,
    p_msg           OUT VARCHAR2
  );

END pkg_zastepstwa;
/

CREATE OR REPLACE PACKAGE pkg_raporty AS

    c_ok             CONSTANT NUMBER := 0;
    c_blad_danych    CONSTANT NUMBER := 1;


    FUNCTION oblicz_przychod(p_przed_id IN NUMBER) RETURN NUMBER;

    FUNCTION pobierz_tytul(p_przed_id IN NUMBER) RETURN VARCHAR2;

    PROCEDURE pobierz_repertuar(
        p_data   IN DATE,
        p_kursor OUT SYS_REFCURSOR
    );

    FUNCTION wolne_sale_pipe(p_data DATE) 
        RETURN t_wolna_sala_tab PIPELINED;

END pkg_raporty;
/


CREATE OR REPLACE PACKAGE BODY pkg_obsada AS


  g_role_cache t_lista_rol;


  e_zajety_zasob       EXCEPTION;
  PRAGMA EXCEPTION_INIT(e_zajety_zasob, -54);
  
  e_brak_kwalifikacji  EXCEPTION;
  e_brak_danych        EXCEPTION;

  FUNCTION zloz_date(p_d IN DATE, p_g IN DATE) RETURN DATE IS
  BEGIN
    RETURN TRUNC(p_d) + (p_g - TRUNC(p_g));
  END;


  FUNCTION czy_wolny(p_emp IN NUMBER, p_d IN DATE, p_g IN DATE) RETURN NUMBER IS
    v_licznik NUMBER; 
    v_termin  DATE := zloz_date(p_d, p_g);
  BEGIN
    SELECT COUNT(*) INTO v_licznik 
      FROM PRZEDSTAWIENIE_PRACOWNIK pp
      JOIN PRZEDSTAWIENIE pr ON pr.ID_PRZEDSTAWIENIA = pp.PRZEDSTAWIENIE_ID_PRZEDSTAWIENIA
     WHERE pp.PRACOWNICY_TEATRU_ID_PRACOWNIKA = p_emp
       AND TRUNC(pr.DATA_PRZEDSTAWIENIA) = TRUNC(v_termin)
       AND TO_CHAR(pr.GODZINA_PRZEDSTAWIENIA, 'HH24:MI') = TO_CHAR(v_termin, 'HH24:MI');
       
    RETURN CASE WHEN v_licznik = 0 THEN 1 ELSE 0 END;
  EXCEPTION WHEN OTHERS THEN RETURN 0;
  END;

  FUNCTION nazwa_roli(p_id IN NUMBER) RETURN VARCHAR2 IS
    v_nazwa VARCHAR2(80);
  BEGIN
    IF g_role_cache.EXISTS(p_id) THEN RETURN g_role_cache(p_id); END IF;
    
    SELECT nazwa_zawodu INTO v_nazwa FROM ZAWOD WHERE ID_zawodu = p_id;
    g_role_cache(p_id) := v_nazwa; 
    RETURN v_nazwa;
  EXCEPTION WHEN NO_DATA_FOUND THEN RETURN 'Nieznana rola ('||p_id||')';
  END;


  FUNCTION znajdz_zastepce(
    p_rola_id IN NUMBER, p_d IN DATE, p_g IN DATE, p_wyklucz_id IN NUMBER
  ) RETURN NUMBER IS
  BEGIN
    FOR r IN (SELECT ID_PRACOWNIKA FROM PRACOWNICY_TEATRU WHERE ZAWOD_id_zawodu = p_rola_id) LOOP
       IF r.ID_PRACOWNIKA <> NVL(p_wyklucz_id, -1) THEN
          IF czy_wolny(r.ID_PRACOWNIKA, p_d, p_g) = 1 THEN
             RETURN r.ID_PRACOWNIKA; 
          END IF;
       END IF;
    END LOOP;
    RETURN NULL; 
  END;


  PROCEDURE pobierz_termin_blokada(p_przed IN NUMBER, p_d OUT DATE, p_g OUT DATE) IS
  BEGIN
    SELECT DATA_PRZEDSTAWIENIA, GODZINA_PRZEDSTAWIENIA INTO p_d, p_g
      FROM PRZEDSTAWIENIE WHERE ID_PRZEDSTAWIENIA = p_przed 
       FOR UPDATE NOWAIT; 
  EXCEPTION WHEN NO_DATA_FOUND THEN RAISE e_brak_danych;
  END;

  PROCEDURE zapisz_role(p_przed IN NUMBER, p_rola IN NUMBER, p_emp IN NUMBER) IS
  BEGIN
    MERGE INTO PRZEDSTAWIENIE_PRACOWNIK target
    USING (SELECT p_przed as pid, p_rola as zid, p_emp as eid FROM DUAL) source
    ON (target.PRZEDSTAWIENIE_ID_PRZEDSTAWIENIA = source.pid AND target.ID_ZAWODU = source.zid)
    WHEN MATCHED THEN UPDATE SET target.PRACOWNICY_TEATRU_ID_PRACOWNIKA = source.eid
    WHEN NOT MATCHED THEN INSERT (PRZEDSTAWIENIE_ID_PRZEDSTAWIENIA, PRACOWNICY_TEATRU_ID_PRACOWNIKA, ID_ZAWODU)
      VALUES (source.pid, source.eid, source.zid);
  END;


  PROCEDURE weryfikuj_kompetencje(p_emp_id IN NUMBER, p_rola_id IN NUMBER) IS
    v_check NUMBER;
    CURSOR c_skills IS
        SELECT 1 FROM PRACOWNICY_TEATRU 
         WHERE ID_PRACOWNIKA = p_emp_id AND ZAWOD_id_zawodu = p_rola_id;
  BEGIN
    OPEN c_skills;
    FETCH c_skills INTO v_check;
    IF c_skills%NOTFOUND THEN
        CLOSE c_skills;
        RAISE e_brak_kwalifikacji;
    END IF;
    CLOSE c_skills;
  END;


  PROCEDURE przypisz_pracownika(
    p_przed_id      IN NUMBER,  
    p_rola_id       IN NUMBER, 
    p_pracownik_id  IN NUMBER, 
    p_status        OUT NUMBER, 
    p_msg           OUT VARCHAR2 
  ) IS
    v_d DATE; v_g DATE; v_zastepca_id NUMBER;
    v_rola_nazwa VARCHAR2(80); 

    CURSOR c_konflikty IS
      SELECT pp.PRZEDSTAWIENIE_ID_PRZEDSTAWIENIA AS przed_id,
             pp.ID_ZAWODU AS id_zawodu
        FROM PRZEDSTAWIENIE_PRACOWNIK pp
        JOIN PRZEDSTAWIENIE pr ON pr.ID_PRZEDSTAWIENIA = pp.PRZEDSTAWIENIE_ID_PRZEDSTAWIENIA
       WHERE pp.PRACOWNICY_TEATRU_ID_PRACOWNIKA = p_pracownik_id
         AND pr.ID_PRZEDSTAWIENIA <> p_przed_id
         AND TRUNC(pr.DATA_PRZEDSTAWIENIA) = TRUNC(v_d)
         AND TO_CHAR(pr.GODZINA_PRZEDSTAWIENIA,'HH24:MI') = TO_CHAR(v_g,'HH24:MI')
       FOR UPDATE OF pp.PRACOWNICY_TEATRU_ID_PRACOWNIKA NOWAIT;

  BEGIN

    weryfikuj_kompetencje(p_pracownik_id, p_rola_id);
    pobierz_termin_blokada(p_przed_id, v_d, v_g);


    FOR r IN c_konflikty LOOP
       v_zastepca_id := znajdz_zastepce(r.id_zawodu, v_d, v_g, p_pracownik_id);

       IF v_zastepca_id IS NULL THEN
          v_rola_nazwa := nazwa_roli(r.id_zawodu);
          p_status := c_error_user;
          p_msg := 'Konflikt! Pracownik gra w spektaklu ' || r.przed_id || 
                   ' (' || v_rola_nazwa || ') i nie ma zastępstwa.';
          ROLLBACK; RETURN;
       END IF;


       UPDATE PRZEDSTAWIENIE_PRACOWNIK
          SET PRACOWNICY_TEATRU_ID_PRACOWNIKA = v_zastepca_id
        WHERE PRZEDSTAWIENIE_ID_PRZEDSTAWIENIA = r.przed_id
          AND ID_ZAWODU = r.id_zawodu;
    END LOOP;

    zapisz_role(p_przed_id, p_rola_id, p_pracownik_id);
    
    v_rola_nazwa := nazwa_roli(p_rola_id);
    p_status := c_ok;
    p_msg := 'Sukces! Przypisano pracownika '||p_pracownik_id||' do roli: '||v_rola_nazwa;
    COMMIT;


  EXCEPTION
    WHEN e_brak_danych THEN
        p_status := c_error_user; p_msg := 'Błąd: Nie znaleziono spektaklu ' || p_przed_id; ROLLBACK;
    WHEN e_brak_kwalifikacji THEN
        p_status := c_error_user; p_msg := 'Błąd: Pracownik nie ma kwalifikacji do tej roli!'; ROLLBACK;
    WHEN DUP_VAL_ON_INDEX THEN
        p_status := c_error_system; p_msg := 'Info: Ten pracownik już tu pracuje.'; ROLLBACK;
    WHEN e_zajety_zasob THEN
        p_status := c_error_system; p_msg := 'System zajęty. Ktoś inny edytuje te dane.'; ROLLBACK;
    WHEN OTHERS THEN
        p_status := c_error_system; p_msg := 'Błąd krytyczny: ' || SQLERRM; ROLLBACK;
  END przypisz_pracownika;

END pkg_obsada;
/


CREATE OR REPLACE PACKAGE BODY pkg_grafik AS


  e_brak_wolnej_sali   EXCEPTION;
  e_rekord_zablokowany EXCEPTION;
  PRAGMA EXCEPTION_INIT(e_rekord_zablokowany, -54);
  e_nieznany_spektakl  EXCEPTION;


  FUNCTION zloz_termin(p_d IN DATE, p_g IN DATE) RETURN DATE IS
  BEGIN
    RETURN TRUNC(p_d) + (p_g - TRUNC(p_g));
  END;


  FUNCTION czy_sala_wolna(p_sala IN NUMBER, p_termin IN DATE) RETURN NUMBER IS
    v_licznik NUMBER;
  BEGIN
    SELECT COUNT(*) INTO v_licznik 
      FROM PRZEDSTAWIENIE
     WHERE SALA_ID_SALI = p_sala
       AND TRUNC(DATA_PRZEDSTAWIENIA) = TRUNC(p_termin)
       AND TO_CHAR(GODZINA_PRZEDSTAWIENIA, 'HH24:MI') = TO_CHAR(p_termin, 'HH24:MI');
       
    RETURN CASE WHEN v_licznik = 0 THEN 1 ELSE 0 END;
  END;


  FUNCTION kto_blokuje(p_sala IN NUMBER, p_termin IN DATE) RETURN NUMBER IS
    v_id NUMBER;
  BEGIN
    SELECT ID_PRZEDSTAWIENIA INTO v_id 
      FROM PRZEDSTAWIENIE
     WHERE SALA_ID_SALI = p_sala
       AND TRUNC(DATA_PRZEDSTAWIENIA) = TRUNC(p_termin)
       AND TO_CHAR(GODZINA_PRZEDSTAWIENIA, 'HH24:MI') = TO_CHAR(p_termin, 'HH24:MI')
     FETCH FIRST 1 ROWS ONLY;
    RETURN v_id;
  EXCEPTION WHEN NO_DATA_FOUND THEN RETURN NULL;
  END;


  FUNCTION znajdz_alternatywe(p_termin IN DATE, p_odwiedzone IN t_num_tab) RETURN NUMBER IS
  BEGIN
    FOR r IN (SELECT ID_SALI FROM SALA ORDER BY ilosc_miejsc ASC) LOOP
   
       IF (p_odwiedzone IS NULL OR NOT (r.ID_SALI MEMBER OF p_odwiedzone)) THEN
          IF czy_sala_wolna(r.ID_SALI, p_termin) = 1 THEN
             RETURN r.ID_SALI; 
          END IF;
       END IF;
    END LOOP;
    RETURN NULL;
  END;

  PROCEDURE zwolnij_sale_kaskadowo(
    p_sala_cel   IN NUMBER,
    p_termin     IN DATE,
    p_odwiedzone IN OUT t_num_tab
  ) IS
    v_intruz_id NUMBER;
    v_nowa_sala NUMBER;
  BEGIN

    IF p_odwiedzone IS NULL THEN p_odwiedzone := t_num_tab(); END IF;
    p_odwiedzone.EXTEND; 
    p_odwiedzone(p_odwiedzone.COUNT) := p_sala_cel;


    IF czy_sala_wolna(p_sala_cel, p_termin) = 1 THEN RETURN; END IF;

    v_intruz_id := kto_blokuje(p_sala_cel, p_termin);
    IF v_intruz_id IS NULL THEN RETURN; END IF; 


    v_nowa_sala := znajdz_alternatywe(p_termin, p_odwiedzone);
    
    IF v_nowa_sala IS NOT NULL THEN

       UPDATE PRZEDSTAWIENIE SET SALA_ID_SALI = v_nowa_sala 
        WHERE ID_PRZEDSTAWIENIA = v_intruz_id;
       RETURN;
    END IF;


    FOR r IN (SELECT ID_SALI FROM SALA WHERE ID_SALI <> p_sala_cel) LOOP

       IF NOT (r.ID_SALI MEMBER OF p_odwiedzone) THEN
          DECLARE 
            v_historia_kopia t_num_tab := p_odwiedzone; 
          BEGIN

             zwolnij_sale_kaskadowo(r.ID_SALI, p_termin, v_historia_kopia);
             

             IF czy_sala_wolna(r.ID_SALI, p_termin) = 1 THEN
                UPDATE PRZEDSTAWIENIE SET SALA_ID_SALI = r.ID_SALI 
                 WHERE ID_PRZEDSTAWIENIA = v_intruz_id;
                RETURN;
             END IF;
          EXCEPTION WHEN OTHERS THEN NULL; 
          END;
       END IF;
    END LOOP;

    RAISE e_brak_wolnej_sali;
  END;

  PROCEDURE przypisz_sale(
    p_przed_id      IN NUMBER,
    p_sala_docel    IN NUMBER,
    p_data          IN DATE,
    p_godz          IN DATE,
    p_status        OUT NUMBER,
    p_msg           OUT VARCHAR2
  ) IS
    v_termin     DATE := zloz_termin(p_data, p_godz);
    v_historia   t_num_tab := t_num_tab();
    v_dummy      NUMBER;
  BEGIN

    BEGIN
      SELECT 1 INTO v_dummy FROM PRZEDSTAWIENIE 
       WHERE ID_PRZEDSTAWIENIA = p_przed_id FOR UPDATE NOWAIT;
    EXCEPTION 
      WHEN NO_DATA_FOUND THEN RAISE e_nieznany_spektakl;
      WHEN e_rekord_zablokowany THEN RAISE; 
    END;

    IF czy_sala_wolna(p_sala_docel, v_termin) = 0 THEN
       zwolnij_sale_kaskadowo(p_sala_docel, v_termin, v_historia);
    END IF;

    UPDATE PRZEDSTAWIENIE
       SET DATA_PRZEDSTAWIENIA = TRUNC(p_data),
           GODZINA_PRZEDSTAWIENIA = v_termin,
           SALA_ID_SALI = p_sala_docel
     WHERE ID_PRZEDSTAWIENIA = p_przed_id;


    p_status := c_sukces;
    p_msg := 'Sukces! Spektakl przypisany do sali '||p_sala_docel||
             ' na godzinę ' || TO_CHAR(v_termin, 'HH24:MI') || '.';
    COMMIT;

  EXCEPTION

    WHEN e_brak_wolnej_sali THEN
       p_status := c_blad_danych;
       p_msg := 'Niepowodzenie: Brak wolnych sal w tym terminie. Algorytm nie znalazł rozwiązania.';
       ROLLBACK;
    WHEN e_nieznany_spektakl THEN
       p_status := c_blad_danych;
       p_msg := 'Błąd: Przedstawienie o ID ' || p_przed_id || ' nie istnieje.';
       ROLLBACK;
    WHEN e_rekord_zablokowany THEN
       p_status := c_blad_systemu;
       p_msg := 'System zajęty: Inny dyspozytor edytuje właśnie ten spektakl. Spróbuj za chwilę.';
       ROLLBACK;
    WHEN OTHERS THEN
       p_status := c_blad_systemu;
       p_msg := 'Błąd krytyczny bazy danych: ' || SQLERRM;
       ROLLBACK;
  END przypisz_sale;


  PROCEDURE optymalizuj_grafik(
    p_data          IN DATE,
    p_godz          IN DATE DEFAULT NULL,
    p_status        OUT NUMBER,
    p_msg           OUT VARCHAR2
  ) IS
     v_termin      DATE;
     v_zajete_sale t_num_tab;
     v_nowa_sala   NUMBER;


     CURSOR c_konflikty(cp_termin DATE) IS
        SELECT ID_PRZEDSTAWIENIA, SALA_ID_SALI
          FROM PRZEDSTAWIENIE
         WHERE TRUNC(DATA_PRZEDSTAWIENIA) = TRUNC(cp_termin)
           AND TO_CHAR(GODZINA_PRZEDSTAWIENIA, 'HH24:MI') = TO_CHAR(cp_termin, 'HH24:MI')
         ORDER BY ID_PRZEDSTAWIENIA
           FOR UPDATE; 

  BEGIN

    IF p_godz IS NULL THEN v_termin := TRUNC(p_data) + 19/24; 
    ELSE v_termin := zloz_termin(p_data, p_godz);
    END IF;

    v_zajete_sale := t_num_tab();


    FOR r IN c_konflikty(v_termin) LOOP
       

       IF r.SALA_ID_SALI MEMBER OF v_zajete_sale THEN
          

          v_nowa_sala := znajdz_alternatywe(v_termin, v_zajete_sale);
          
          IF v_nowa_sala IS NOT NULL THEN

             UPDATE PRZEDSTAWIENIE 
                SET SALA_ID_SALI = v_nowa_sala 
              WHERE ID_PRZEDSTAWIENIA = r.ID_PRZEDSTAWIENIA;

             v_zajete_sale.EXTEND; 
             v_zajete_sale(v_zajete_sale.COUNT) := v_nowa_sala;
          END IF;
       
       ELSE
          v_zajete_sale.EXTEND; 
          v_zajete_sale(v_zajete_sale.COUNT) := r.SALA_ID_SALI;
       END IF;

    END LOOP;

    p_status := c_sukces;
    p_msg := 'Grafik zoptymalizowany dla daty: ' || TO_CHAR(p_data, 'YYYY-MM-DD');
    COMMIT;

  EXCEPTION
    WHEN OTHERS THEN
       p_status := c_blad_systemu;
       p_msg := 'Błąd optymalizacji: ' || SQLERRM;
       ROLLBACK;
  END optymalizuj_grafik;

END pkg_grafik;
/


CREATE OR REPLACE PACKAGE BODY pkg_bilety AS


  e_brak_miejsc        EXCEPTION;
  e_bilet_istnieje     EXCEPTION;
  e_nieznany_spektakl  EXCEPTION;
  e_blad_ceny          EXCEPTION;


  FUNCTION pobierz_znizke(p_nazwa IN VARCHAR2) RETURN NUMBER IS
    v_mapa t_mapa_znizek;
  BEGIN

    v_mapa('Brak')      := 0.00;
    v_mapa('Ulgowa')    := 0.10; 
    v_mapa('Senior')    := 0.20; 
    v_mapa('Rodzinna')  := 0.25; 
    v_mapa('Studencka') := 0.51; 

    IF v_mapa.EXISTS(p_nazwa) THEN
       RETURN v_mapa(p_nazwa);
    ELSE
       RETURN 0; 
    END IF;
  END;


  FUNCTION sprawdz_dostepnosc(p_przed_id IN NUMBER) RETURN NUMBER IS
    v_pojemnosc NUMBER;
    v_sprzedano NUMBER;
    

    CURSOR c_info_spektakl IS
        SELECT s.ILOSC_MIEJSC
          FROM PRZEDSTAWIENIE p
          JOIN SALA s ON p.SALA_ID_SALI = s.ID_SALI
         WHERE p.ID_PRZEDSTAWIENIA = p_przed_id;
  BEGIN

    OPEN c_info_spektakl;
    FETCH c_info_spektakl INTO v_pojemnosc;
    
    IF c_info_spektakl%NOTFOUND THEN
       CLOSE c_info_spektakl;
       RETURN -1; 
    END IF;
    CLOSE c_info_spektakl;

    SELECT COUNT(*) INTO v_sprzedano
      FROM BILETY
     WHERE PRZEDSTAWIENIE_ID_PRZEDSTAWIENIA = p_przed_id;


    RETURN GREATEST(v_pojemnosc - v_sprzedano, 0);
  END;


  PROCEDURE sprzedaj_bilet(
    p_bilet_id      IN NUMBER,
    p_przed_id      IN NUMBER,
    p_klient_id     IN NUMBER,
    p_znizka_nazwa  IN VARCHAR2,
    p_typ_miejsca   IN NUMBER,
    p_platnosc      IN VARCHAR2,
    p_koszt_out     OUT NUMBER,
    p_status        OUT NUMBER,
    p_msg           OUT VARCHAR2
  ) IS

    v_cennik     t_przedzial_cenowy := t_przedzial_cenowy(100.00, 150.00, 250.00); 
    v_cena_baza  NUMBER;
    v_procent    NUMBER;
    v_wolne      NUMBER;
    v_check      NUMBER;
  BEGIN
    p_status := c_sukces;
    p_msg    := NULL;

    SELECT COUNT(*) INTO v_check FROM BILETY WHERE ID_BILETU = p_bilet_id;
    IF v_check > 0 THEN
       RAISE e_bilet_istnieje;
    END IF;

    v_wolne := sprawdz_dostepnosc(p_przed_id);
    
    IF v_wolne = -1 THEN RAISE e_nieznany_spektakl; END IF;
    IF v_wolne <= 0 THEN RAISE e_brak_miejsc; END IF;


    IF p_typ_miejsca < 1 OR p_typ_miejsca > v_cennik.COUNT THEN
       v_cena_baza := v_cennik(1); 
    ELSE
       v_cena_baza := v_cennik(p_typ_miejsca);
    END IF;

    v_procent   := pobierz_znizke(p_znizka_nazwa);
    p_koszt_out := v_cena_baza - (v_cena_baza * v_procent);

    INSERT INTO BILETY (
        ID_BILETU, KOSZT_BILETU, RODZAJ_TRANSAKCJI, RODZAJ_PLATNOSCI, 
        ZNIZKA, PRZEDSTAWIENIE_ID_PRZEDSTAWIENIA, KLIENCI_ID_KLIENTA
    ) VALUES (
        p_bilet_id, p_koszt_out, 'Kasa', p_platnosc,
        p_znizka_nazwa, p_przed_id, p_klient_id
    );

    p_msg := 'Sukces! Sprzedano bilet za kwotę: ' || p_koszt_out || ' PLN. ' ||
             'Pozostało miejsc: ' || (v_wolne - 1);
    COMMIT;

  EXCEPTION
    WHEN e_bilet_istnieje THEN
       p_status := c_blad_danych;
       p_msg    := 'Błąd: Numer biletu ' || p_bilet_id || ' jest już zajęty.';
       ROLLBACK;

    WHEN e_brak_miejsc THEN
       p_status := c_blad_danych;
       p_msg    := 'Przykro nam, ale wszystkie bilety zostały wyprzedane!';
       ROLLBACK;

    WHEN e_nieznany_spektakl THEN
       p_status := c_blad_danych;
       p_msg    := 'Błąd: Wybrane przedstawienie nie istnieje.';
       ROLLBACK;

    WHEN OTHERS THEN
       p_status := c_blad_systemu;
       p_msg    := 'Błąd systemu: ' || SQLERRM;
       ROLLBACK;
  END sprzedaj_bilet;

END pkg_bilety;
/

CREATE OR REPLACE PACKAGE BODY pkg_zastepstwa AS

  e_brak_zastepstwa   EXCEPTION;
  e_nie_w_obsadzie    EXCEPTION;
  e_rekord_zablokowany EXCEPTION;
  PRAGMA EXCEPTION_INIT(e_rekord_zablokowany, -54);


  FUNCTION zloz_termin(p_d IN DATE, p_g IN DATE) RETURN DATE IS
  BEGIN
    RETURN TRUNC(p_d) + (p_g - TRUNC(p_g));
  END;


  FUNCTION czy_pracownik_wolny(p_emp IN NUMBER, p_d IN DATE, p_g IN DATE) RETURN NUMBER IS
    v_cnt NUMBER; v_dt DATE := zloz_termin(p_d, p_g);
  BEGIN
    SELECT COUNT(*) INTO v_cnt FROM PRZEDSTAWIENIE_PRACOWNIK pp
      JOIN PRZEDSTAWIENIE pr ON pr.ID_PRZEDSTAWIENIA = pp.PRZEDSTAWIENIE_ID_PRZEDSTAWIENIA
     WHERE pp.PRACOWNICY_TEATRU_ID_PRACOWNIKA = p_emp
       AND TRUNC(pr.DATA_PRZEDSTAWIENIA) = TRUNC(v_dt)
       AND TO_CHAR(pr.GODZINA_PRZEDSTAWIENIA, 'HH24:MI') = TO_CHAR(v_dt, 'HH24:MI');
    RETURN CASE WHEN v_cnt = 0 THEN 1 ELSE 0 END;
  END;

  FUNCTION dostepni_pracownicy_pipe(
    p_rola_id IN NUMBER, p_d IN DATE, p_g IN DATE
  ) RETURN t_num_list PIPELINED IS
  BEGIN

    FOR r IN (SELECT ID_PRACOWNIKA FROM PRACOWNICY_TEATRU WHERE ZAWOD_id_zawodu = p_rola_id) 
    LOOP

      IF czy_pracownik_wolny(r.ID_PRACOWNIKA, p_d, p_g) = 1 THEN

         PIPE ROW(r.ID_PRACOWNIKA); 
      END IF;
    END LOOP;
    RETURN;
  END;


  PROCEDURE zglos_chorobe(
    p_przed_id      IN NUMBER,    
    p_rola_id       IN NUMBER,    
    p_chory_prac_id IN NUMBER,    
    p_status        OUT NUMBER,
    p_msg           OUT VARCHAR2
  ) IS
    v_d DATE; v_g DATE; v_nowy_id NUMBER;
    v_dummy NUMBER;

    CURSOR c_weryfikacja IS
        SELECT 1
          FROM PRZEDSTAWIENIE_PRACOWNIK
         WHERE PRZEDSTAWIENIE_ID_PRZEDSTAWIENIA = p_przed_id
           AND ID_ZAWODU = p_rola_id
           AND PRACOWNICY_TEATRU_ID_PRACOWNIKA = p_chory_prac_id
           FOR UPDATE NOWAIT; 

  BEGIN
    p_status := c_sukces; p_msg := NULL;

    OPEN c_weryfikacja;
    FETCH c_weryfikacja INTO v_dummy;
    IF c_weryfikacja%NOTFOUND THEN
       CLOSE c_weryfikacja;
       RAISE e_nie_w_obsadzie;
    END IF;
    CLOSE c_weryfikacja;


    SELECT DATA_PRZEDSTAWIENIA, GODZINA_PRZEDSTAWIENIA INTO v_d, v_g
      FROM PRZEDSTAWIENIE WHERE ID_PRZEDSTAWIENIA = p_przed_id;

  
    BEGIN
        SELECT COLUMN_VALUE INTO v_nowy_id
          FROM TABLE(pkg_zastepstwa.dostepni_pracownicy_pipe(p_rola_id, v_d, v_g))
         WHERE COLUMN_VALUE <> p_chory_prac_id 
         FETCH FIRST 1 ROWS ONLY; 
    EXCEPTION 
        WHEN NO_DATA_FOUND THEN RAISE e_brak_zastepstwa;
    END;

    UPDATE PRZEDSTAWIENIE_PRACOWNIK
       SET PRACOWNICY_TEATRU_ID_PRACOWNIKA = v_nowy_id
     WHERE PRZEDSTAWIENIE_ID_PRZEDSTAWIENIA = p_przed_id
       AND ID_ZAWODU = p_rola_id
       AND PRACOWNICY_TEATRU_ID_PRACOWNIKA = p_chory_prac_id; 

    p_msg := 'Sukces! Zastępstwo znalezione. Pracownik ' || p_chory_prac_id || 
             ' został zastąpiony przez pracownika ' || v_nowy_id || '.';
    COMMIT;


  EXCEPTION
    WHEN e_nie_w_obsadzie THEN
       p_status := c_blad_danych;
       p_msg := 'Błąd: Pracownik ID '||p_chory_prac_id||' nie jest przypisany do tego spektaklu w tej roli.';
       ROLLBACK;
    WHEN e_brak_zastepstwa THEN
       p_status := c_blad_logiczny;
       p_msg := 'ALARM: Brak dostępnych zastępców! Wszyscy aktorzy z tą rolą są zajęci.';
       ROLLBACK;
    WHEN e_rekord_zablokowany THEN
       p_status := c_blad_logiczny;
       p_msg := 'System zajęty: Ktoś właśnie edytuje tę obsadę.';
       ROLLBACK;
    WHEN OTHERS THEN
       p_status := c_blad_logiczny;
       p_msg := 'Błąd krytyczny: ' || SQLERRM;
       ROLLBACK;
  END zglos_chorobe;

END pkg_zastepstwa;
/

CREATE OR REPLACE PACKAGE BODY pkg_raporty AS

    e_brak_daty EXCEPTION;

    FUNCTION oblicz_przychod(p_przed_id IN NUMBER) RETURN NUMBER IS
        v_suma NUMBER;
    BEGIN
        SELECT NVL(SUM(KOSZT_BILETU), 0) 
          INTO v_suma
          FROM BILETY
         WHERE PRZEDSTAWIENIE_ID_PRZEDSTAWIENIA = p_przed_id;
         
        RETURN v_suma;
    EXCEPTION WHEN OTHERS THEN
        RETURN 0; 
    END;

    FUNCTION pobierz_tytul(p_przed_id IN NUMBER) RETURN VARCHAR2 IS
        v_tytul VARCHAR2(100);
    BEGIN
        SELECT s.TYTUL_SPEKTAKLU
          INTO v_tytul
          FROM PRZEDSTAWIENIE p
          JOIN SPEKTAKL s ON p.SPEKTAKL_ID_SPEKTAKLU = s.ID_SPEKTAKLU
         WHERE p.ID_PRZEDSTAWIENIA = p_przed_id;
         
        RETURN v_tytul;
    EXCEPTION WHEN NO_DATA_FOUND THEN
        RETURN 'Nieznany Spektakl';
    END;


    PROCEDURE pobierz_repertuar(
        p_data   IN DATE,
        p_kursor OUT SYS_REFCURSOR
    ) IS
    BEGIN
        IF p_data IS NULL THEN RAISE e_brak_daty; END IF;

        OPEN p_kursor FOR
            SELECT p.ID_PRZEDSTAWIENIA,
                   TO_CHAR(p.GODZINA_PRZEDSTAWIENIA, 'HH24:MI') AS GODZINA,
                   s.TYTUL_SPEKTAKLU,

                   pkg_raporty.oblicz_przychod(p.ID_PRZEDSTAWIENIA) || ' PLN' AS PRZYCHOD,
                   sl.NUMER_SALI,
                   sc.KROTKI_OPIS_SCENERII
              FROM PRZEDSTAWIENIE p
              JOIN SPEKTAKL s      ON p.SPEKTAKL_ID_SPEKTAKLU = s.ID_SPEKTAKLU
              JOIN SALA sl         ON p.SALA_ID_SALI = sl.ID_SALI
              JOIN SCENERIA sc     ON p.SCENERIA_ID_SCENERII = sc.ID_SCENERII
             WHERE TRUNC(p.DATA_PRZEDSTAWIENIA) = TRUNC(p_data)
             ORDER BY p.GODZINA_PRZEDSTAWIENIA;

    EXCEPTION
        WHEN e_brak_daty THEN
            OPEN p_kursor FOR SELECT NULL FROM DUAL WHERE 1=0;
            RAISE_APPLICATION_ERROR(-20001, 'Błąd raportu: Nie podano daty!');
        WHEN OTHERS THEN
            IF p_kursor%ISOPEN THEN CLOSE p_kursor; END IF;
            RAISE_APPLICATION_ERROR(-20099, 'Błąd: ' || SQLERRM);
    END pobierz_repertuar;


    FUNCTION wolne_sale_pipe(p_data DATE) 
        RETURN t_wolna_sala_tab PIPELINED 
    IS
        v_start_h NUMBER := 16; v_end_h NUMBER := 22;
        v_check_dt DATE; v_count NUMBER; v_sala_cnt NUMBER;
    BEGIN
        IF p_data IS NULL THEN RAISE_APPLICATION_ERROR(-20002, 'Brak daty.'); END IF;
        
        SELECT COUNT(*) INTO v_sala_cnt FROM SALA;
        IF v_sala_cnt = 0 THEN RAISE_APPLICATION_ERROR(-20003, 'Brak sal.'); END IF;

        FOR h IN v_start_h .. v_end_h LOOP
            v_check_dt := TRUNC(p_data) + NUMTODSINTERVAL(h, 'HOUR');
            FOR r IN (SELECT ID_SALI, NUMER_SALI, ILOSC_MIEJSC FROM SALA ORDER BY NUMER_SALI) LOOP
                SELECT COUNT(*) INTO v_count
                  FROM PRZEDSTAWIENIE
                 WHERE SALA_ID_SALI = r.ID_SALI
                   AND TRUNC(DATA_PRZEDSTAWIENIA) = TRUNC(v_check_dt)
                   AND TO_CHAR(GODZINA_PRZEDSTAWIENIA, 'HH24') = TO_CHAR(v_check_dt, 'HH24');

                IF v_count = 0 THEN
                    PIPE ROW(t_wolna_sala_obj(TRUNC(p_data), h || ':00', r.NUMER_SALI, r.ILOSC_MIEJSC));
                END IF;
            END LOOP; 
        END LOOP; 
        RETURN;
    END wolne_sale_pipe;

END pkg_raporty;
/


CREATE SEQUENCE seq_klienci_id
    START WITH 1000
    INCREMENT BY 1
    NOCACHE;
/

CREATE OR REPLACE TRIGGER trg_klienci_bi
    BEFORE INSERT ON KLIENCI
    FOR EACH ROW
BEGIN
    IF :NEW.ID_KLIENTA IS NULL THEN
        SELECT seq_klienci_id.NEXTVAL
        INTO :NEW.ID_KLIENTA
        FROM dual;
    END IF;
END;
/


CREATE SEQUENCE seq_przeds_prac_id
    START WITH 3000
    INCREMENT BY 1
    NOCACHE;
/

CREATE OR REPLACE TRIGGER trg_przeds_prac_bi
    BEFORE INSERT ON PRZEDSTAWIENIE_PRACOWNIK
    FOR EACH ROW
BEGIN
    IF :NEW.ID_PRZEDSTAWIENIE_PRACOWNIK IS NULL THEN
        SELECT seq_przeds_prac_id.NEXTVAL
        INTO :NEW.ID_PRZEDSTAWIENIE_PRACOWNIK
        FROM dual;
    END IF;
END;
/